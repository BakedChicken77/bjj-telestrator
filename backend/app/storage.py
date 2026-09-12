"""Atomic, project-relative filesystem persistence with no client server paths."""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import threading
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4

from pydantic import ValidationError

from .errors import DomainError, conflict
from .migrations import MAX_REVISION, migrate_document
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
        folder = (self.root / require_uuid(project_id)).resolve()
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

    def save(self, project: Project, *, existing: bool = True) -> Project:
        with self.lock:
            folder = self.project_dir(project.projectId)
            if existing:
                old = self.load(project.projectId)
                if (old.source.model_dump() != project.source.model_dump()
                        or old.proxy.model_dump() != project.proxy.model_dump()
                        or old.createdAt != project.createdAt):
                    raise StorageError('Source video, proxy metadata, and creation time cannot be changed')
                if project.revision != old.revision:
                    raise conflict(old.revision)
                if old.revision >= MAX_REVISION:
                    raise StorageError('The project revision limit was reached. Recover this review as a copy.')
            elif (folder / 'project.json').exists():
                raise StorageError('This project already exists')
            for media in (project.source, project.proxy):
                if not asset_path(folder, media.asset).is_file():
                    raise StorageError('A required video asset is missing')
            self.validate_voiceovers(project)
            saved = project.model_copy(update={'updatedAt': utc_now(),
                                               'revision': old.revision + 1 if existing else 1}, deep=True)
            atomic_json(folder / 'project.json', saved.model_dump(mode='json'))
            return saved

    def list(self) -> list[dict[str, object]]:
        projects = []
        for directory in self.root.iterdir():
            if not directory.is_dir() or not (directory / 'project.json').is_file():
                continue
            try:
                project = self.load(directory.name)
                projects.append({'projectId': project.projectId, 'projectName': project.projectName,
                                 'updatedAt': project.updatedAt, 'durationSec': project.source.durationSec,
                                 'annotationCount': len(project.annotations)})
            except DomainError as exc:
                # Keep upgrade-required/corrupt projects visible and recoverable.
                projects.append({'projectId': directory.name, 'projectName': 'Unavailable project',
                                 'updatedAt': '', 'durationSec': 0, 'annotationCount': 0,
                                 'unavailableCode': exc.code})
            except (StorageError, FileNotFoundError):
                log.warning('Skipping unreadable project', extra={'projectId': directory.name})
        return sorted(projects, key=lambda item: str(item['updatedAt']), reverse=True)

    def delete(self, project_id: str) -> None:
        with self.lock:
            if self.leases.get(project_id, 0):
                raise DomainError('ASSET_BUSY', 'Finish or cancel active media operations before deleting this project.', 409)
            self.load(project_id)
            shutil.rmtree(self.project_dir(project_id))


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

    def recover_copy(self, draft: Project) -> Project:
        """Install a new, independent review only after every asset is validated."""
        with self.lock:
            original = self.load(draft.projectId)
            for field in ('source', 'proxy', 'createdAt'):
                if getattr(original, field) != getattr(draft, field):
                    raise StorageError('Recovery cannot change imported media metadata')
            self.validate_voiceovers(draft)
            old_folder = self.project_dir(draft.projectId)
            refs = {draft.source.asset, draft.proxy.asset, *(v.asset for v in draft.voiceovers)}
            required = sum(asset_path(old_folder, ref).stat().st_size for ref in refs)
            if shutil.disk_usage(self.root).free < required + 32 * 1024**2:
                raise DomainError('STORAGE_LOW', 'Not enough space to recover a separate copy.', 507)
            new_id = str(uuid4())
            folder = self.create_dir(new_id)
            try:
                document = draft.model_dump(mode='json')
                mapping = {draft.projectId: new_id,
                           **{item.id: str(uuid4()) for item in [*draft.annotations, *draft.voiceovers]}}

                def remap(value: object) -> object:
                    if isinstance(value, str):
                        return mapping.get(value, value)
                    if isinstance(value, list):
                        return [remap(item) for item in value]
                    if isinstance(value, dict):
                        return {key: remap(item) for key, item in value.items()}
                    return value

                document = remap(document)
                document['revision'] = 1
                document['projectName'] = draft.projectName[:142] + ' (recovered copy)'
                document['createdAt'] = document['updatedAt'] = utc_now()
                for media in (draft.source, draft.proxy):
                    target = asset_path(folder, media.asset)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(asset_path(old_folder, media.asset), target)
                for before, after in zip(draft.voiceovers, document['voiceovers'], strict=True):
                    after['asset'] = f'voiceover/{after["id"]}.wav'
                    shutil.copyfile(asset_path(old_folder, before.asset), asset_path(folder, after['asset']))
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
