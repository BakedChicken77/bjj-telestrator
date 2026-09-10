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
        try:
            return Project.model_validate_json((self.project_dir(project_id) / 'project.json').read_text('utf-8'))
        except FileNotFoundError:
            raise
        except (ValidationError, ValueError, OSError) as exc:
            log.exception('Project document could not be read', extra={'projectId': project_id})
            raise StorageError('The project document is damaged or uses an unsupported schema version') from exc

    def save(self, project: Project, *, existing: bool = True) -> Project:
        with self.lock:
            folder = self.project_dir(project.projectId)
            if existing:
                old = self.load(project.projectId)
                if (old.source.model_dump() != project.source.model_dump()
                        or old.proxy.model_dump() != project.proxy.model_dump()
                        or old.createdAt != project.createdAt):
                    raise StorageError('Source video, proxy metadata, and creation time cannot be changed')
            for media in (project.source, project.proxy):
                if not asset_path(folder, media.asset).is_file():
                    raise StorageError('A required video asset is missing')
            self.validate_voiceovers(project)
            saved = project.model_copy(update={'updatedAt': utc_now()}, deep=True)
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
            except (StorageError, FileNotFoundError):
                log.warning('Skipping unreadable project', extra={'projectId': directory.name})
        return sorted(projects, key=lambda item: str(item['updatedAt']), reverse=True)

    def delete(self, project_id: str) -> None:
        with self.lock:
            self.load(project_id)
            shutil.rmtree(self.project_dir(project_id))


    def voiceover_metadata(self, project_id: str, clip_id: str) -> Voiceover:
        self.load(project_id)
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
            clip = self.voiceover_metadata(project_id, clip_id)
            project = self.load(project_id)
            project.voiceovers = [item for item in project.voiceovers if item.id != clip_id]
            self.save(project)
            folder = self.project_dir(project_id)
            asset_path(folder, clip.asset).unlink(missing_ok=True)
            (folder / 'voiceover' / f'{clip.id}.json').unlink(missing_ok=True)
