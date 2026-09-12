"""Durable versions and deletion preserve source/retained media across failures."""
from __future__ import annotations

import errno
import shutil
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from test_export_recovery import isolated

from app.assets import digest_file, manifest_assets
from app.config import Config
from app.errors import DomainError
from app.main import create_app
from app.models import Project, Voiceover
from app.recovery import ProjectRecovery
from app.storage import ProjectStore, StorageError, atomic_json
from test_backend import stored_project, wait_job


def with_recording(store, project):
    identifier = str(uuid4())
    clip = Voiceover(id=identifier, asset=f'voiceover/{identifier}.wav', startSec=1, endSec=2,
                     durationSec=1, recordedAt=project.createdAt, codec='pcm_s16le', sampleRate=48000, channels=1)
    temporary = store.project_dir(project.projectId) / 'temp/take.wav'
    temporary.write_bytes(b'immutable audio for storage tests')
    store.register_voiceover(project.projectId, clip, temporary)
    return store.save(project.model_copy(update={'voiceovers': [clip]}))


def test_checkpoint_restore_retains_removed_take_prior_edit_and_monotonic_revision(tmp_path):
    store = ProjectStore(tmp_path)
    project = with_recording(store, stored_project(store))
    source = store.project_dir(project.projectId) / project.source.asset
    before = digest_file(source)
    recovery = ProjectRecovery(store)
    checkpoint = recovery.checkpoint(project.projectId, project.revision, 'Primeira revisão')
    current = store.save(project.model_copy(update={'projectName': 'After changes', 'annotations': [], 'voiceovers': []}))
    restored = recovery.restore_checkpoint(project.projectId, checkpoint['checkpointId'], current.revision)
    assert restored.revision == current.revision + 1
    assert restored.annotations == project.annotations and restored.voiceovers == project.voiceovers
    entries = recovery.checkpoints(project.projectId)
    assert len(entries) == 2
    previous = next(item for item in entries if item['label'].startswith('Before restoring'))
    assert recovery.read_checkpoint(project.projectId, previous['checkpointId'])['input']['project']['annotations'] == []
    assert digest_file(source) == before
    assert ProjectStore(tmp_path).load(project.projectId).model_dump() == restored.model_dump()
    undone = recovery.restore_checkpoint(project.projectId, previous['checkpointId'], restored.revision)
    assert undone.projectName == 'After changes' and undone.voiceovers == []
    assert (store.project_dir(project.projectId) / project.voiceovers[0].asset).is_file()


@pytest.mark.parametrize('operation', ['checkpoint', 'restore', 'duplicate', 'trash'])
def test_stale_recovery_never_replaces_newer_project(tmp_path, operation):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    recovery = ProjectRecovery(store)
    checkpoint = recovery.checkpoint(project.projectId, project.revision, 'Original')
    saved = store.save(project.model_copy(update={'projectName': 'Other tab'}))
    actions = {'checkpoint': lambda: recovery.checkpoint(project.projectId, project.revision, 'Stale'),
               'restore': lambda: recovery.restore_checkpoint(project.projectId, checkpoint['checkpointId'], project.revision),
               'duplicate': lambda: recovery.duplicate(project.projectId, project.revision),
               'trash': lambda: recovery.trash(project.projectId, project.revision)}
    with pytest.raises(DomainError) as failure:
        actions[operation]()
    assert failure.value.code == 'PROJECT_CONFLICT'
    assert store.load(project.projectId).model_dump() == saved.model_dump()
    assert recovery.deleted() == []


def test_failed_before_restore_write_leaves_current_project_untouched(tmp_path, monkeypatch):
    import app.recovery as module
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    recovery = ProjectRecovery(store)
    checkpoint = recovery.checkpoint(project.projectId, project.revision, 'Initial')
    saved = store.save(project.model_copy(update={'annotations': []}))
    def fail(_path, _value):
        raise OSError(errno.ENOSPC, 'injected checkpoint failure')
    monkeypatch.setattr(module, 'atomic_json', fail)
    with pytest.raises(OSError):
        recovery.restore_checkpoint(project.projectId, checkpoint['checkpointId'], saved.revision)
    assert store.load(project.projectId).model_dump() == saved.model_dump()
    assert store.leases[project.projectId] == 0


def test_duplicate_remaps_ids_and_references_without_sharing_files(tmp_path):
    store = ProjectStore(tmp_path)
    project = with_recording(store, stored_project(store))
    document = project.model_dump(mode='json')
    document['futureOptional'] = {'annotationRef': project.annotations[0].id, 'clipRef': project.voiceovers[0].id}
    project = store.save(Project.model_validate(document))
    recovery = ProjectRecovery(store)
    recovery.checkpoint(project.projectId, project.revision, 'Original only')
    copy = recovery.duplicate(project.projectId, project.revision)
    assert copy.projectId != project.projectId and copy.revision == 1
    assert copy.annotations[0].id != project.annotations[0].id and copy.voiceovers[0].id != project.voiceovers[0].id
    assert copy.model_dump()['futureOptional'] == {'annotationRef': copy.annotations[0].id, 'clipRef': copy.voiceovers[0].id}
    assert recovery.checkpoints(copy.projectId) == []
    first = store.project_dir(project.projectId) / project.source.asset
    second = store.project_dir(copy.projectId) / copy.source.asset
    assert first.stat().st_ino != second.stat().st_ino
    assert digest_file(first) == digest_file(second)
    store.save(copy.model_copy(update={'annotations': [], 'voiceovers': []}))
    assert len(store.load(project.projectId).annotations) == len(store.load(project.projectId).voiceovers) == 1


def test_copy_failure_and_missing_checkpoint_asset_preserve_original(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    recovery = ProjectRecovery(store)
    checkpoint = recovery.checkpoint(project.projectId, project.revision, 'Original')
    def fail(*_args, **_kwargs):
        raise OSError(errno.ENOSPC, 'injected copy failure')
    monkeypatch.setattr(shutil, 'copyfile', fail)
    with pytest.raises(OSError):
        recovery.duplicate(project.projectId, project.revision)
    assert len(store.list()) == 1
    (store.project_dir(project.projectId) / project.source.asset).unlink()
    with pytest.raises(DomainError):
        recovery.restore_checkpoint(project.projectId, checkpoint['checkpointId'], project.revision)
    assert store.load(project.projectId).revision == project.revision


def test_trash_restore_retains_entire_folder_and_retry_after_restart(tmp_path):
    store = ProjectStore(tmp_path)
    project = with_recording(store, stored_project(store))
    recovery = ProjectRecovery(store)
    checkpoint = recovery.checkpoint(project.projectId, project.revision, 'Keep')
    manager = isolated(store)
    job = manager.create(project)
    assert wait_job(manager, job.jobId) == 'completed'
    manager.close()
    store.save(project.model_copy(update={'voiceovers': []}))
    folder = store.project_dir(project.projectId)
    manifest_assets(store, project, proxy=True)  # Inventory caches are established before the move.
    contents = {str(path.relative_to(folder)): path.read_bytes() for path in folder.rglob('*') if path.is_file()}
    recovery.trash(project.projectId, project.revision + 1)
    assert not folder.exists() and store.list() == []
    recovery = ProjectRecovery(ProjectStore(tmp_path))
    trash = recovery.deleted()[0]
    restored, copied = recovery.restore_deleted(trash['trashId'])
    assert not copied and restored.projectId == project.projectId
    assert {str(path.relative_to(folder)): path.read_bytes() for path in folder.rglob('*') if path.is_file()} == contents
    assert recovery.checkpoints(project.projectId)[0]['checkpointId'] == checkpoint['checkpointId']
    assert recovery.deleted() == []
    manager = isolated(store)
    try:
        retry = manager.retry(job.jobId)
        assert wait_job(manager, retry.jobId) == 'completed'
        assert retry.projectRevision == project.revision
    finally:
        manager.close()


def test_trash_collision_creates_copy_and_preserves_both_full_projects(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    recovery = ProjectRecovery(store)
    folder = store.project_dir(project.projectId)
    recovery.trash(project.projectId, project.revision)
    entry = recovery.deleted()[0]
    archived = recovery.read_trash(entry['trashId'])[1]
    shutil.copytree(archived, folder)  # Simulates an independently restored same-ID project.
    changed = store.save(project.model_copy(update={'projectName': 'Existing newer review'}))
    restored, copied = recovery.restore_deleted(entry['trashId'])
    assert copied and restored.projectId != project.projectId
    assert store.load(project.projectId).model_dump() == changed.model_dump()
    assert recovery.deleted()[0] == entry
    recovery.permanently_delete(entry['trashId'])
    assert recovery.deleted() == [] and len(store.list()) == 2


def test_busy_failed_rename_and_unsafe_trash_paths_leave_sources(tmp_path, monkeypatch):
    import app.recovery as module
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    recovery = ProjectRecovery(store)
    store.acquire_lease(project.projectId)
    with pytest.raises(DomainError) as busy:
        recovery.trash(project.projectId, project.revision)
    assert busy.value.code == 'ASSET_BUSY'
    store.release_lease(project.projectId)
    def fail(*_args):
        raise OSError(errno.EACCES, 'injected rename failure')
    monkeypatch.setattr(module.os, 'rename', fail)
    with pytest.raises(OSError):
        recovery.trash(project.projectId, project.revision)
    assert store.load(project.projectId).revision == project.revision and recovery.deleted() == []
    with pytest.raises(StorageError):
        recovery.permanently_delete('../source')
    identifier = str(uuid4())
    recovery.trash_entry(identifier).symlink_to(store.project_dir(project.projectId), target_is_directory=True)
    with pytest.raises(StorageError):
        recovery.restore_deleted(identifier)
    assert (store.project_dir(project.projectId) / project.source.asset).read_bytes() == b'source'


def test_recovery_api_conditional_delete_restore_and_checkpoint_ownership(tmp_path):
    app = create_app(Config(data_dir=tmp_path))
    with TestClient(app, base_url='http://localhost:8000') as client:
        project = stored_project(app.state.store)
        url = f'/api/projects/{project.projectId}'
        headers = {'If-Match': f'"{project.revision}"'}
        assert client.delete(url).status_code == 428
        checkpoint = client.post(url + '/checkpoints', json={'label': 'One'}, headers=headers)
        assert checkpoint.status_code == 200
        assert 'input' not in checkpoint.json()
        other = stored_project(app.state.store)
        assert client.post(f'/api/projects/{other.projectId}/checkpoints/{checkpoint.json()["checkpointId"]}/restore', headers=headers).status_code == 404
        assert client.delete(url, headers=headers).status_code == 204
        trash = client.get('/api/recently-deleted').json()[0]
        result = client.post(f'/api/recently-deleted/{trash["trashId"]}/restore')
        assert result.status_code == 200 and result.json()['copied'] is False
        assert result.json()['project']['projectId'] == project.projectId
        assert client.delete(url, headers=headers).status_code == 204
        trash = client.get('/api/recently-deleted').json()[0]
        assert client.delete(f'/api/recently-deleted/{trash["trashId"]}').status_code == 204
        assert client.get('/api/recently-deleted').json() == []


def test_checkpoint_rejects_hash_damage_and_unknown_required_capability(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    recovery = ProjectRecovery(store)
    entry = recovery.checkpoint(project.projectId, project.revision, 'Original')
    path = recovery.checkpoint_path(project.projectId, entry['checkpointId'])
    original = recovery.read_checkpoint(project.projectId, entry['checkpointId'])
    original['input']['assets'][0]['sha256'] = '0' * 64
    atomic_json(path, original)
    with pytest.raises(DomainError) as bad_hash:
        recovery.restore_checkpoint(project.projectId, entry['checkpointId'], project.revision)
    assert bad_hash.value.code == 'ASSET_CHANGED'
    original['input']['project']['requiredCapabilities'].append('future.visual.v1')
    atomic_json(path, original)
    with pytest.raises(DomainError):
        recovery.restore_checkpoint(project.projectId, entry['checkpointId'], project.revision)
    assert store.load(project.projectId).revision == project.revision
