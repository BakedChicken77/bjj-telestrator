"""Project-local durable versions, independent copies and recoverable deletion."""
from __future__ import annotations

import json
import os
import shutil
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from .assets import manifest_assets, require_space, space_estimate
from .errors import DomainError, conflict
from .migrations import MAX_REVISION
from .models import Project
from .render_plan import build_plan, validate_plan, verify_assets
from .storage import ProjectStore, StorageError, asset_path, atomic_json, require_uuid, utc_now


def read_record(path: Path) -> dict:
    if path.is_symlink() or path.stat().st_size > 32 * 1024**2:
        raise DomainError('RECOVERY_INVALID', 'This recovery record is damaged. Its files were preserved.', 409)
    try:
        value = json.loads(path.read_bytes())
        if not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1:
            raise ValueError()
        return value
    except (ValueError, TypeError) as exc:
        raise DomainError('RECOVERY_INVALID', 'This recovery record is damaged or needs a newer app.', 409) from exc


class ProjectRecovery:
    def __init__(self, store: ProjectStore):
        self.store = store

    def current(self, project_id: str, revision: int) -> Project:
        project = self.store.load(project_id)
        if project.revision != revision:
            raise conflict(project.revision)
        return project

    def checkpoint_path(self, project_id: str, checkpoint_id: str) -> Path:
        return asset_path(self.store.project_dir(project_id), f'checkpoints/{require_uuid(checkpoint_id)}.json')

    def checkpoint(self, project_id: str, revision: int, label: str) -> dict:
        if not isinstance(label, str) or not 1 <= len(label.strip()) <= 120:
            raise StorageError('Checkpoint labels must contain 1–120 characters')
        with self.store.lock:
            project = self.current(project_id, revision)
            self.store.acquire_lease(project_id)
        try:
            plan = build_plan(self.store, project)
            identifier = str(uuid4())
            entry = {'version': 1, 'checkpointId': identifier, 'projectId': project_id,
                     'revision': revision, 'label': label.strip(), 'createdAt': utc_now(), 'input': plan}
            with self.store.lock:
                self.current(project_id, revision)
                if len(self.checkpoints(project_id)) >= 1000:
                    raise DomainError('RECOVERY_LIMIT', 'This project already has 1,000 checkpoints.', 409)
                atomic_json(self.checkpoint_path(project_id, identifier), entry)
            return {key: value for key, value in entry.items() if key != 'input'}
        finally:
            self.store.release_lease(project_id)

    def read_checkpoint(self, project_id: str, checkpoint_id: str) -> dict:
        value = read_record(self.checkpoint_path(project_id, checkpoint_id))
        try:
            if value['projectId'] != project_id or value['checkpointId'] != checkpoint_id:
                raise ValueError()
            validate_plan(value['input'], project_id, value['revision'])
            if (not isinstance(value['label'], str) or not 1 <= len(value['label']) <= 120
                    or not isinstance(value['createdAt'], str) or len(value['createdAt']) > 80
                    or datetime.fromisoformat(value['createdAt'].replace('Z', '+00:00')).tzinfo is None):
                raise ValueError()
        except (ValueError, TypeError, KeyError) as exc:
            if isinstance(exc, DomainError):
                raise
            raise DomainError('RECOVERY_INVALID', 'This checkpoint is damaged or unsupported. Its files were preserved.', 409) from exc
        return value

    def checkpoints(self, project_id: str) -> list[dict]:
        self.store.load(project_id)
        folder = self.checkpoint_path(project_id, str(uuid4())).parent
        result = []
        for path in folder.glob('*.json'):
            if len(result) >= 1000:
                raise DomainError('RECOVERY_LIMIT', 'This project exceeds the supported 1,000 checkpoints.', 409)
            value = self.read_checkpoint(project_id, path.stem)
            result.append({key: item for key, item in value.items() if key != 'input'})
        return sorted(result, key=lambda item: (item['createdAt'], item['checkpointId']), reverse=True)

    def restore_checkpoint(self, project_id: str, checkpoint_id: str, revision: int) -> Project:
        with self.store.lock:
            self.current(project_id, revision)
            self.store.acquire_lease(project_id)
        try:
            entry = self.read_checkpoint(project_id, checkpoint_id)
            verify_assets(self.store.project_dir(project_id), entry['input'])
            # This checkpoint is durable before any replacement of the current edits.
            self.checkpoint(project_id, revision, 'Before restoring ' + entry['label'][:100])
            with self.store.lock:
                current = self.current(project_id, revision)
                document = entry['input']['project'].copy()
                for field in ('projectId', 'revision', 'createdAt', 'source', 'proxy'):
                    document[field] = current.model_dump(mode='json')[field]
                return self.store.save(Project.model_validate(document))
        finally:
            self.store.release_lease(project_id)

    def duplicate(self, project_id: str, revision: int) -> Project:
        with self.store.lock:
            return self.store.recover_copy(self.current(project_id, revision), suffix=' (copy)')

    def trash_root(self) -> Path:
        return asset_path(self.store.root, 'recently-deleted')

    def trash_entry(self, trash_id: str) -> Path:
        return asset_path(self.trash_root(), require_uuid(trash_id))

    def trash(self, project_id: str, revision: int) -> None:
        with self.store.lock:
            project = self.current(project_id, revision)
            if self.store.leases.get(project_id, 0):
                raise DomainError('ASSET_BUSY', 'Finish or cancel active media operations before deleting this project.', 409)
            identifier = str(uuid4())
            entry = self.trash_entry(identifier)
            target = entry / 'projects' / project_id
            target.parent.mkdir(parents=True)
            # Metadata first, then one same-filesystem rename. A crash never leaves
            # a moved project without its recovery identity. Empty entries are ignored.
            atomic_json(entry / 'metadata.json', {'version': 1, 'trashId': identifier,
                        'projectId': project_id, 'projectName': project.projectName,
                        'revision': revision, 'deletedAt': utc_now()})
            os.rename(self.store.project_dir(project_id), target)

    def read_trash(self, trash_id: str) -> tuple[dict, Path]:
        entry = self.trash_entry(trash_id)
        value = read_record(asset_path(entry, 'metadata.json'))
        try:
            if (value['trashId'] != trash_id or not isinstance(value['projectName'], str)
                    or not 1 <= len(value['projectName']) <= 160
                    or type(value['revision']) is not int or not 1 <= value['revision'] <= MAX_REVISION
                    or not isinstance(value['deletedAt'], str) or len(value['deletedAt']) > 80
                    or datetime.fromisoformat(value['deletedAt'].replace('Z', '+00:00')).tzinfo is None):
                raise ValueError()
            folder = asset_path(entry, f'projects/{require_uuid(value["projectId"])}')
            if not folder.is_dir():
                raise FileNotFoundError()
        except (ValueError, TypeError, KeyError) as exc:
            raise DomainError('RECOVERY_INVALID', 'This deleted project has damaged recovery metadata.', 409) from exc
        return value, folder

    def deleted(self) -> list[dict]:
        result = []
        for entry in self.trash_root().glob('*'):
            if len(result) >= 1000:
                raise DomainError('RECOVERY_LIMIT', 'This workspace exceeds the supported 1,000 deleted projects.', 409)
            try:
                value, _ = self.read_trash(entry.name)
                result.append(value)
            except FileNotFoundError:
                continue  # An interrupted rename left the live project intact.
        return sorted(result, key=lambda item: (item['deletedAt'], item['trashId']), reverse=True)

    def restore_deleted(self, trash_id: str) -> tuple[Project, bool]:
        with self.store.lock:
            value, folder = self.read_trash(trash_id)
            archived = ProjectStore(self.trash_entry(trash_id))
            project = archived.load(value['projectId'])
            archived.validate_voiceovers(project)
            assets = manifest_assets(archived, project, proxy=True)
            verify_assets(folder, {'assets': assets})
            target = self.store.project_dir(project.projectId)
            if target.exists():
                # Retain the full deleted directory. The new copy contains the saved
                # review and its required media; old job/checkpoint IDs stay there.
                return self.store.recover_copy(project, source_store=archived), True
            os.rename(folder, target)
            # Installation succeeded. Wrapper cleanup is optional and must never
            # turn a successful restore into a misleading failed operation.
            shutil.rmtree(self.trash_entry(trash_id), ignore_errors=True)
            return self.store.load(project.projectId), False

    def permanently_delete(self, trash_id: str) -> None:
        with self.store.lock:
            self.read_trash(trash_id)  # UUID-scoped ownership; never follow links.
            shutil.rmtree(self.trash_entry(trash_id))


def copy_preflight(store: ProjectStore, entries: list[dict]) -> None:
    require_space(store.root, space_estimate('duplicate', incoming=sum(entry['byteSize'] for entry in entries), output=0))
