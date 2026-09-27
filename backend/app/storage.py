"""Atomic, project-relative filesystem persistence with no client server paths."""
from __future__ import annotations

import json
import logging
import math
import os
import re
import shutil
import stat
import threading
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4

from pydantic import ValidationError

from .errors import DomainError, conflict
from .migrations import CAPABILITIES, MAX_REVISION, SCHEMA_VERSION, migrate_document
from .models import Project, Voiceover

log = logging.getLogger(__name__)


class StorageError(Exception):
    pass


def utc_now() -> str:
    return datetime.now(UTC).isoformat().replace('+00:00', 'Z')


def safe_filename(name: str, fallback: str = 'video') -> str:
    value = re.sub(r'[^A-Za-z0-9._ -]', '_', name.replace('\\', '/').split('/')[-1])
    value = value.strip(' .')[:180]
    return value or fallback


def require_uuid(value: str) -> str:
    try:
        if str(UUID(value)) != value:
            raise ValueError()
    except (ValueError, AttributeError) as exc:
        raise StorageError('Invalid resource identifier') from exc
    return value


def asset_path(project_dir: Path, relative: str) -> Path:
    if (not relative or '\\' in relative or ':' in relative or '\x00' in relative
            or relative.startswith('/') or any(v in ('', '.', '..') for v in relative.split('/'))):
        raise StorageError('Invalid asset reference')
    root = project_dir.resolve()
    cursor = root
    for part in relative.split('/'):
        cursor = cursor / part
        if cursor.is_symlink():
            raise StorageError('Symbolic links are not supported for project assets')
    result = (root / relative).resolve()
    if not result.is_relative_to(root) or result == root:
        raise StorageError('Invalid asset reference')
    return result


def atomic_json(path: Path, document: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f'.{path.name}.{uuid4()}.tmp'
    try:
        with temporary.open('x', encoding='utf-8') as handle:
            json.dump(document, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class ProjectStore:
    def __init__(self, data_dir: Path):
        self.root = (data_dir / 'projects').resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.asset_lock = threading.RLock()
        self.leases: dict[str, int] = {}

    def acquire_lease(self, project_id: str) -> None:
        with self.lock:
            self.load(project_id)
            self.leases[project_id] = self.leases.get(project_id, 0) + 1

    def release_lease(self, project_id: str) -> None:
        with self.lock:
            self.leases[project_id] = max(0, self.leases.get(project_id, 0) - 1)

    def project_dir(self, project_id: str) -> Path:
        candidate = self.root / require_uuid(project_id)
        if candidate.is_symlink():
            raise StorageError('Symbolic links are not supported for project directories')
        folder = candidate.resolve()
        if not folder.is_relative_to(self.root):
            raise StorageError('Invalid project directory')
        return folder

    def create_dir(self, project_id: str) -> Path:
        folder = self.project_dir(project_id)
        folder.mkdir(exist_ok=False)
        for child in ('source', 'proxy', 'voiceover', 'exports', 'temp'):
            (folder / child).mkdir()
        return folder

    def load(self, project_id: str) -> Project:
        with self.lock:
            path = self.project_dir(project_id) / 'project.json'
            try:
                if path.stat().st_size > 32 * 1024**2:
                    raise DomainError('PROJECT_CORRUPT', 'Project metadata exceeds 32 MiB.')
                original = path.read_bytes()
                document = json.loads(original)
                migrated = migrate_document(document)
                project = Project.model_validate(migrated)
                if project.projectId != project_id:
                    raise DomainError('PROJECT_CORRUPT', 'The project identifier does not match its storage.')
                if document['schemaVersion'] != migrated['schemaVersion']:
                    for media in (project.source, project.proxy):
                        if not asset_path(path.parent, media.asset).is_file():
                            raise DomainError('ASSET_MISSING', 'A required video asset is missing.')
                    self.validate_voiceovers(project)
                    backup = path.with_name(f'project.pre-migration-v{document["schemaVersion"]}.json')
                    if backup.exists():
                        if backup.read_bytes() != original:
                            raise DomainError('PROJECT_CORRUPT', 'The preserved migration copy differs. Restore from a verified backup.')
                    else:
                        # An interruption before installation leaves the old document
                        # and its exact backup; retry safely repeats this migration.
                        temporary = backup.with_suffix('.tmp')
                        try:
                            with temporary.open('wb') as handle:
                                handle.write(original)
                                handle.flush()
                                os.fsync(handle.fileno())
                            os.replace(temporary, backup)
                        finally:
                            temporary.unlink(missing_ok=True)
                    atomic_json(path, project.model_dump(mode='json'))
                    reopened = Project.model_validate_json(path.read_bytes())
                    if reopened.model_dump() != project.model_dump():
                        raise DomainError('PROJECT_CORRUPT', 'The migrated project could not be verified. The original was preserved.')
                    return reopened
                return project
            except (FileNotFoundError, DomainError, OSError):
                raise
            except (ValidationError, ValueError) as exc:
                raise DomainError('PROJECT_CORRUPT', 'The project document is damaged.') from exc

    def save(self, project: Project, *, existing: bool = True, replacing_proxy: bool = False) -> Project:
        with self.lock:
            folder = self.project_dir(project.projectId)
            if existing:
                old = self.load(project.projectId)
                if project.revision != old.revision:
                    raise conflict(old.revision)
                if (old.source.model_dump() != project.source.model_dump()
                        or (not replacing_proxy and old.proxy.model_dump() != project.proxy.model_dump())
                        or old.createdAt != project.createdAt):
                    raise StorageError('Source video, proxy metadata, and creation time cannot be changed')
                if old.revision >= MAX_REVISION:
                    raise StorageError('The project revision limit was reached. Recover this review as a copy.')
            elif (folder / 'project.json').exists():
                raise StorageError('This project already exists')
            for media in (project.source, project.proxy):
                path = asset_path(folder, media.asset)
                # An absent derived preview must not prevent saving the edits
                # that repair will preserve. New/replacement previews stay required.
                if media is project.proxy and existing and not replacing_proxy and not path.exists():
                    continue
                if not path.is_file():
                    raise StorageError('A required video asset is missing')
            self.validate_voiceovers(project)
            saved = project.model_copy(update={'updatedAt': utc_now(),
                                               'revision': old.revision + 1 if existing else 1}, deep=True)
            atomic_json(folder / 'project.json', saved.model_dump(mode='json'))
            self._cache_summary(saved)
            return saved

    @staticmethod
    def _summary_fingerprint(path: Path) -> list[int]:
        value = path.lstat()
        if not stat.S_ISREG(value.st_mode):
            raise StorageError('Project metadata must be a regular file')
        return [value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns]

    @staticmethod
    def _summary(project: Project) -> dict[str, object]:
        return {'projectId': project.projectId, 'projectName': project.projectName,
                'updatedAt': project.updatedAt, 'durationSec': project.source.durationSec,
                'annotationCount': len(project.annotations), 'revision': project.revision}

    def _cache_summary(self, project: Project, fingerprint: list[int] | None = None) -> None:
        # Disposable display metadata. Failure after a durable save is not a
        # failed save; open/save/export still validate the authoritative document.
        try:
            folder = self.project_dir(project.projectId)
            current = self._summary_fingerprint(folder / 'project.json')
            if fingerprint is not None and current != fingerprint:
                return
            atomic_json(asset_path(folder, 'project.index.json'), {
                'version': 1, 'schemaVersion': SCHEMA_VERSION, 'capabilities': list(CAPABILITIES),
                'fingerprint': current, 'summary': self._summary(project)})
        except (OSError, StorageError):
            log.warning('Could not refresh disposable project summary', extra={'projectId': project.projectId})

    def _list_summary(self, project_id: str) -> dict[str, object]:
        folder = self.project_dir(project_id)
        fingerprint = self._summary_fingerprint(folder / 'project.json')
        try:
            path = asset_path(folder, 'project.index.json')
            with path.open('rb') as handle:
                data = handle.read(8193)
            if len(data) > 8192:
                raise ValueError('Oversized index')
            index = json.loads(data)
            if (index['version'] != 1 or index['schemaVersion'] != SCHEMA_VERSION
                    or index['capabilities'] != list(CAPABILITIES) or index['fingerprint'] != fingerprint):
                raise ValueError('Stale index')
            item = index['summary']
            if (set(item) != {'projectId', 'projectName', 'updatedAt', 'durationSec', 'annotationCount', 'revision'}
                    or item['projectId'] != project_id
                    or not isinstance(item['projectName'], str) or not item['projectName'].strip()
                    or not 1 <= len(item['projectName']) <= 160
                    or not isinstance(item['updatedAt'], str) or len(item['updatedAt']) > 80
                    or type(item['durationSec']) not in (float, int) or not math.isfinite(item['durationSec'])
                    or not 0 < item['durationSec'] <= 86400
                    or type(item['annotationCount']) is not int or not 0 <= item['annotationCount'] <= 2000
                    or type(item['revision']) is not int or not 1 <= item['revision'] <= MAX_REVISION):
                raise ValueError('Invalid index')
            if datetime.fromisoformat(item['updatedAt'].replace('Z', '+00:00')).tzinfo is None:
                raise ValueError('Invalid index timestamp')
            return item
        except (OSError, StorageError, ValueError, KeyError, TypeError, OverflowError, RecursionError):
            project = self.load(project_id)
            self._cache_summary(project, fingerprint)
            return self._summary(project)

    def list(self) -> list[dict[str, object]]:
        with self.lock:
            return self._list_locked()

    def _list_locked(self) -> list[dict[str, object]]:
        projects = []
        for directory in self.root.iterdir():
            if not directory.is_dir() or not (directory / 'project.json').is_file():
                continue
            try:
                projects.append(self._list_summary(directory.name))
            except DomainError as exc:
                # Keep upgrade-required/corrupt projects visible and recoverable.
                projects.append({'projectId': directory.name, 'projectName': 'Unavailable project',
                                 'updatedAt': '', 'durationSec': 0, 'annotationCount': 0,
                                 'unavailableCode': exc.code})
            except (StorageError, FileNotFoundError):
                log.warning('Skipping unreadable project', extra={'projectId': directory.name})
        return sorted(projects, key=lambda item: str(item['updatedAt']), reverse=True)

    def delete(self, project_id: str) -> None:
        from .recovery import ProjectRecovery
        with self.lock:
            ProjectRecovery(self).trash(project_id, self.load(project_id).revision)

    def voiceover_metadata(self, project_id: str, clip_id: str) -> Voiceover:
        folder = self.project_dir(project_id)
        clip_id = require_uuid(clip_id)
        try:
            clip = Voiceover.model_validate_json((folder / 'voiceover' / f'{clip_id}.json').read_text('utf-8'))
        except FileNotFoundError as exc:
            raise StorageError('The voiceover is not registered. Upload or rerecord the audio clip.') from exc
        except (ValidationError, ValueError) as exc:
            log.exception('Voiceover registry is damaged', extra={'projectId': project_id})
            raise StorageError('The voiceover asset metadata is damaged') from exc
        if clip.id != clip_id or clip.asset != f'voiceover/{clip_id}.wav':
            raise StorageError('The voiceover asset metadata is invalid')
        if not asset_path(folder, clip.asset).is_file():
            raise StorageError('A voiceover asset is missing. Rerecord the clip.')
        return clip

    def recover_copy(self, draft: Project, *, suffix: str = ' (recovered copy)', source_store: ProjectStore | None = None) -> Project:
        """Install a new, independent review only after every asset is validated."""
        from .assets import digest_file, manifest_assets
        from .recovery import copy_preflight
        source_store = source_store or self
        with self.lock:
            original = source_store.load(draft.projectId)
            for field in ('source', 'createdAt'):
                if getattr(original, field) != getattr(draft, field):
                    raise StorageError('Recovery cannot change imported media metadata')
            # A regenerated preview is derived from the same immutable source.
            # Resolve it here so stale drafts never authorize arbitrary asset paths.
            draft = draft.model_copy(update={'proxy': original.proxy})
            source_store.validate_voiceovers(draft)
            old_folder = source_store.project_dir(draft.projectId)
            entries = manifest_assets(source_store, draft, proxy=True)
            copy_preflight(self, entries)
            expected = {entry['reference']: entry['sha256'] for entry in entries}

            def copy_asset(reference: str, target: Path) -> None:
                source = asset_path(old_folder, reference)
                shutil.copyfile(source, target)
                if digest_file(target) != expected[reference] or digest_file(source) != expected[reference]:
                    raise DomainError('ASSET_CHANGED', 'A copied asset failed checksum verification. The original was preserved.', 409)
            new_id = str(uuid4())
            folder = self.create_dir(new_id)
            try:
                document = draft.model_dump(mode='json')
                mapping = {draft.projectId: new_id,
                           **{item.id: str(uuid4()) for item in [*draft.annotations, *draft.voiceovers]}}
                literal_fields = {'text', 'projectName', 'originalFilename'}

                def remap(value: object) -> object:
                    if isinstance(value, str):
                        return mapping.get(value, value)
                    if isinstance(value, list):
                        return [remap(item) for item in value]
                    if isinstance(value, dict):
                        # User content is literal even when it equals an object UUID.
                        return {key: item if key in literal_fields else remap(item) for key, item in value.items()}
                    return value

                document = remap(document)
                document['revision'] = 1
                document['projectName'] = draft.projectName[:160 - len(suffix)] + suffix
                document['createdAt'] = document['updatedAt'] = utc_now()
                for media in (draft.source, draft.proxy):
                    target = asset_path(folder, media.asset)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    copy_asset(media.asset, target)
                for before, after in zip(draft.voiceovers, document['voiceovers'], strict=True):
                    after['asset'] = f'voiceover/{after["id"]}.wav'
                    copy_asset(before.asset, asset_path(folder, after['asset']))
                    atomic_json(folder / 'voiceover' / f'{after["id"]}.json', after)
                return self.save(Project.model_validate(document), existing=False)
            except BaseException:
                shutil.rmtree(folder, ignore_errors=True)
                raise

    def validate_voiceovers(self, project: Project) -> None:
        for clip in project.voiceovers:
            registered = self.voiceover_metadata(project.projectId, clip.id)
            immutable = ('id', 'asset', 'durationSec', 'recordedAt', 'codec', 'sampleRate', 'channels')
            if any(getattr(clip, field) != getattr(registered, field) for field in immutable):
                raise StorageError('Voiceover asset identity, duration, recording date, and audio metadata cannot be changed')

    def register_voiceover(self, project_id: str, clip: Voiceover, temporary_audio: Path) -> Voiceover:
        with self.lock:
            self.load(project_id)  # Do not recreate a project deleted during normalization.
            folder = self.project_dir(project_id)
            if clip.asset != f'voiceover/{require_uuid(clip.id)}.wav':
                raise StorageError('Invalid voiceover asset reference')
            target = asset_path(folder, clip.asset)
            metadata = folder / 'voiceover' / f'{clip.id}.json'
            if target.exists() or metadata.exists():
                raise StorageError('This recording identifier already exists')
            try:
                os.replace(temporary_audio, target)
                atomic_json(metadata, clip.model_dump(mode='json'))
            except Exception:
                target.unlink(missing_ok=True)
                metadata.unlink(missing_ok=True)
                raise
            return clip

    def delete_voiceover(self, project_id: str, clip_id: str) -> None:
        with self.lock:
            self.voiceover_metadata(project_id, clip_id)
            raise DomainError('ASSET_RETAINED', 'Remove the take in the editor. Recording files are retained for undo, recovery and export retry.', 409)
