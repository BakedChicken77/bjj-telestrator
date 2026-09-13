"""Immutable asset inventory and conservative, operation-specific disk estimates.

Manifests are storage-owned sidecars, never part of undo or an autosave payload.
No source/recording garbage collection is enabled: retaining all registered takes
also protects browser undo stacks and recovery drafts that the server cannot see.
"""
from __future__ import annotations

import hashlib
import math
import os
import shutil
import threading
from pathlib import Path
from uuid import uuid4

from .errors import DomainError
from .models import Project
from .storage import ProjectStore, StorageError, asset_path, atomic_json

MIB = 1024**2


def immutable_file(folder: Path, reference: str) -> Path:
    try:
        path = asset_path(folder, reference)
    except StorageError as exc:
        raise DomainError('ASSET_UNSAFE', 'A project asset has an unsafe path or symbolic link.') from exc
    cursor = folder
    for part in reference.split('/'):
        cursor = cursor / part
        if cursor.is_symlink():
            raise DomainError('ASSET_UNSAFE', 'Symbolic links are not supported for project assets.')
    if not path.is_file():
        raise DomainError('ASSET_MISSING', 'A required media asset is missing.', 404)
    return path


def digest_file(path: Path, cancelled: threading.Event | None = None) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        while chunk := handle.read(MIB):
            if cancelled and cancelled.is_set():
                from .renderer import ExportCancelled
                raise ExportCancelled()
            digest.update(chunk)
    return digest.hexdigest()


def fingerprint(path: Path) -> list[str]:
    stat = path.stat()
    # Strings preserve nanosecond precision in JSON across runtimes.
    return [str(stat.st_size), str(stat.st_mtime_ns), str(stat.st_ctime_ns)]


def required_assets(project: Project, *, proxy: bool = False) -> dict[str, tuple[str, dict]]:
    result = {project.source.asset: ('source', project.source.model_dump(mode='json'))}
    if proxy:
        result[project.proxy.asset] = ('proxy', project.proxy.model_dump(mode='json'))
    for clip in project.voiceovers:
        result[clip.asset] = ('voiceover', {key: getattr(clip, key) for key in (
            'durationSec', 'codec', 'sampleRate', 'channels', 'recordedAt')})
    return result


def manifest_assets(store: ProjectStore, project: Project, *, proxy: bool = False, cancel: threading.Event | None = None) -> list[dict]:
    """Hash changed/new files incrementally; never silently replace an old identity."""
    folder = store.project_dir(project.projectId)
    path, cache_path = asset_path(folder, 'assets.json'), asset_path(folder, 'assets.cache.json')
    with store.asset_lock:
        import json
        try:
            for metadata_file in (path, cache_path):
                if metadata_file.exists() and metadata_file.stat().st_size > 32 * MIB:
                    raise ValueError()
            manifest = json.loads(path.read_text()) if path.exists() else {'version': 1, 'assets': []}
            cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
            if (type(manifest['version']) is not int or manifest['version'] != 1
                    or not isinstance(manifest['assets'], list) or len(manifest['assets']) > 100_000
                    or not isinstance(cache, dict)):
                raise ValueError()
            existing = {asset['reference']: asset for asset in manifest['assets']}
            if len(existing) != len(manifest['assets']):
                raise ValueError()
        except (ValueError, KeyError, TypeError) as exc:
            raise DomainError('ASSET_MANIFEST_INVALID', 'The asset inventory is damaged or needs a newer app.') from exc
        result = []
        changed = False
        for reference, (kind, metadata) in required_assets(project, proxy=proxy).items():
            file = immutable_file(folder, reference)
            stamp = fingerprint(file)
            old = existing.get(reference)
            if old and cache.get(reference) == stamp:
                entry = old
            else:
                digest = digest_file(file, cancel) if cancel else digest_file(file)
                if stamp != fingerprint(file):
                    raise DomainError('ASSET_CHANGED', 'A media file changed while it was being checked. Retry after restoring the original.')
                if old and (old['sha256'] != digest or old['byteSize'] != file.stat().st_size):
                    raise DomainError('ASSET_CHANGED', 'A retained media asset has changed. Restore its original file before exporting.')
                entry = {'assetId': old['assetId'] if old else str(uuid4()), 'kind': kind,
                         'reference': reference, 'byteSize': file.stat().st_size,
                         'sha256': digest, 'metadata': metadata}
                existing[reference], cache[reference] = entry, stamp
                changed = True
            result.append(entry)
        if changed:
            atomic_json(path, {'version': 1, 'assets': sorted(existing.values(), key=lambda entry: entry['reference'])})
            atomic_json(cache_path, cache)
        return result


def space_estimate(operation: str, *, output: int, working: int = 0, incoming: int = 0) -> dict:
    subtotal = output + working + incoming
    margin = max(100 * MIB, math.ceil(subtotal * 0.2))
    return {'operation': operation, 'incomingBytes': incoming, 'outputBytes': output,
            'workingBytes': working, 'safetyBytes': margin, 'requiredBytes': subtotal + margin}


def export_estimate(project: Project) -> dict:
    source, settings = project.source, project.exportSettings
    from .renderer import output_dimensions
    width, height = output_dimensions(source)
    # CRF does not guarantee a bitrate. This is a planning estimate, not a limit.
    bitrate = min(120_000_000, max(1_000_000, width * height * settings.fps * 0.18 * 2 ** ((23 - settings.crf) / 6)))
    output = math.ceil(project.source.durationSec * (bitrate + 192000) / 8)
    # FFmpeg retains one PNG per distinct annotation state and may relocate MP4
    # atoms for faststart. Budget raw RGBA (PNG can compress far smaller).
    states = 2 * len(project.annotations) + 1
    return space_estimate('export', output=output, working=output + width * height * 4 * states)


def proxy_estimate(duration: float, incoming: int = 0) -> dict:
    return space_estimate('import', incoming=incoming, output=math.ceil(duration * 12_000_000 / 8),
                          working=32 * MIB)


def recording_estimate(duration: float, incoming: int = 0) -> dict:
    return space_estimate('recording', incoming=incoming, output=math.ceil(duration * 48000 * 2), working=16 * MIB)


def require_space(folder: Path, estimate: dict, reserved: int = 0) -> None:
    available = shutil.disk_usage(folder).free
    required = estimate['requiredBytes'] + reserved
    if available < required:
        raise DomainError('STORAGE_LOW', 'Not enough free storage for this operation. Free space or remove completed MP4s, then retry.',
                          507, requiredBytes=required, availableBytes=available)


def storage_summary(store: ProjectStore, project: Project) -> dict:
    folder = store.project_dir(project.projectId)
    totals = {'sourceBytes': 0, 'proxyBytes': 0, 'recordingBytes': 0, 'exportBytes': 0,
              'temporaryBytes': 0, 'metadataBytes': 0}
    categories = {'source': 'sourceBytes', 'proxy': 'proxyBytes', 'voiceover': 'recordingBytes',
                  'temp': 'temporaryBytes'}
    count = 0
    for root, dirs, files in os.walk(folder, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(root) / name).is_symlink()]
        for name in files:
            count += 1
            if count > 100_000:
                raise DomainError('STORAGE_LIMIT', 'This project has too many storage entries to inspect.')
            file = Path(root) / name
            if file.is_symlink():
                continue
            try:
                size = file.stat().st_size
            except FileNotFoundError:
                continue  # A completed worker may remove temporary files during this read.
            relative = file.relative_to(folder)
            category = categories.get(relative.parts[0], 'metadataBytes')
            if relative.parts[0] == 'exports' and file.suffix == '.mp4':
                category = 'exportBytes'
            totals[category] += size
    return {'projectId': project.projectId, 'revision': project.revision, **totals,
            'totalBytes': sum(totals.values()), 'availableBytes': shutil.disk_usage(folder).free,
            'exportEstimate': export_estimate(project), 'recordingsRetained': True}
