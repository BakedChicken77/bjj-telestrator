"""Conservative collection of obsolete generated previews only.

Sources and every recording remain pinned for unreported browser history. Recovery
copies resolve the current derived preview, so old browser drafts remain usable.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from uuid import UUID

from .errors import DomainError, conflict
from .storage import ProjectStore, asset_path

GRACE_SECONDS = 24 * 60 * 60


def candidates(store: ProjectStore, project_id: str, now: float | None = None) -> list[Path]:
    folder = store.project_dir(project_id)
    project = store.load(project_id)
    references = {project.proxy.asset}
    count = total = 0
    def collect(value, depth=0):
        if depth > 64:
            raise DomainError('CLEANUP_BLOCKED', 'Recovery metadata is too deeply nested. Preview files were retained.', 409)
        if isinstance(value, str) and value.startswith('proxy/'):
            references.add(value)
        elif isinstance(value, list):
            for item in value:
                collect(item, depth + 1)
        elif isinstance(value, dict):
            for item in value.values():
                collect(item, depth + 1)
    for root, dirs, files in os.walk(folder, followlinks=False):
        if any((Path(root) / name).is_symlink() for name in dirs):
            raise DomainError('CLEANUP_BLOCKED', 'Linked recovery folders must be repaired before preview cleanup.', 409)
        for name in files:
            count += 1
            if count > 100_000:
                raise DomainError('CLEANUP_BLOCKED', 'This project has too many files to safely check retention.', 409)
            path = Path(root) / name
            if path.suffix != '.json' or (path.parent == folder and path.name in ('assets.json', 'assets.cache.json', 'project.index.json')):
                continue  # Inventories and disposable summaries do not own assets.
            if path.is_symlink() or path.stat().st_size > 32 * 1024**2:
                raise DomainError('CLEANUP_BLOCKED', 'Recovery metadata needs repair before preview cleanup.', 409)
            total += path.stat().st_size
            if total > 256 * 1024**2:
                raise DomainError('CLEANUP_BLOCKED', 'Recovery metadata exceeds the bounded cleanup scan. Files were retained.', 409)
            try:
                collect(json.loads(path.read_bytes()))
            except (ValueError, RecursionError) as error:
                raise DomainError('CLEANUP_BLOCKED', 'Damaged recovery metadata prevents safe cleanup. Files were retained.', 409) from error
    cutoff = (time.time() if now is None else now) - GRACE_SECONDS
    result = []
    for path in asset_path(folder, 'proxy').glob('*.mp4'):
        # Original named previews and unknown files are retained conservatively.
        try:
            if str(UUID(path.stem)) != path.stem:
                continue
        except ValueError:
            continue
        if path.is_symlink() or f'proxy/{path.name}' in references:
            continue
        if path.is_file() and path.stat().st_mtime <= cutoff:
            result.append(path)
    return result


def preview_cleanup(store: ProjectStore, project_id: str, revision: int | None = None, *, remove=False) -> dict:
    with store.lock:
        project = store.load(project_id)
        if remove and project.revision != revision:
            raise conflict(project.revision)
        if store.leases.get(project_id, 0):
            raise DomainError('ASSET_BUSY', 'Finish or cancel active media operations before cleaning previews.', 409)
        files = candidates(store, project_id)
        size = sum(path.stat().st_size for path in files)
        if remove:
            for path in files:
                path.unlink()
        return {'files': len(files), 'bytes': size, 'graceHours': 24, 'removed': remove}
