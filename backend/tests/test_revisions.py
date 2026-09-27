"""Cross-runtime conformance and real filesystem/HTTP recovery failures."""
from __future__ import annotations

import hashlib
import json
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.config import Config
from app.errors import DomainError
from app.main import create_app
from app.migrations import migrate_document
from app.models import Project
from app.storage import ProjectStore
from test_backend import stored_project

FIXTURES = json.loads((Path(__file__).parents[2] / 'tests/fixtures/project-conformance.json').read_text())


@pytest.mark.parametrize('case', FIXTURES['cases'], ids=lambda case: case['name'])
def test_shared_conformance(case):
    if case['valid']:
        assert Project.model_validate(case['document']).schemaVersion == 2
    else:
        with pytest.raises((ValidationError, DomainError)):
            Project.model_validate(case['document'])


def test_migration_exact_backup_reopen_and_interrupted_install(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    path = store.project_dir(project.projectId) / 'project.json'
    value = project.model_dump(mode='json')
    value['schemaVersion'] = 1
    del value['revision']
    del value['requiredCapabilities']
    original = json.dumps(value, ensure_ascii=False, indent=3).encode()
    path.write_bytes(original)
    import app.storage as storage
    atomic = storage.atomic_json
    monkeypatch.setattr(storage, 'atomic_json', lambda *_args: (_ for _ in ()).throw(OSError('injected write failure')))
    with pytest.raises(OSError):
        store.load(project.projectId)
    assert path.read_bytes() == original
    assert path.with_name('project.pre-migration-v1.json').read_bytes() == original
    monkeypatch.setattr(storage, 'atomic_json', atomic)
    migrated = ProjectStore(tmp_path).load(project.projectId)
    assert migrated.schemaVersion == 2 and migrated.revision == 1
    assert store.load(project.projectId) == migrated
    assert path.with_name('project.pre-migration-v1.json').read_bytes() == original
    assert migrate_document(FIXTURES['cases'][0]['document']) == FIXTURES['migrationExpected']
    assert Project.model_validate(FIXTURES['cases'][0]['document']).model_dump(mode='json') == FIXTURES['migrationExpected']


def test_concurrent_writers_and_failed_atomic_save(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    barrier = threading.Barrier(2)
    def save(name):
        target = project.model_copy(update={'projectName': name}, deep=True)
        barrier.wait()
        try:
            return store.save(target)
        except DomainError as error:
            return error
    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(save, ['first', 'second']))
    assert sum(isinstance(item, Project) for item in results) == 1
    assert sum(isinstance(item, DomainError) and item.code == 'PROJECT_CONFLICT' for item in results) == 1
    saved = store.load(project.projectId)
    assert saved.revision == 2
    import app.storage as storage
    replace = storage.os.replace
    monkeypatch.setattr(storage.os, 'replace', lambda *_args: (_ for _ in ()).throw(OSError('disk full')))
    with pytest.raises(OSError):
        store.save(saved.model_copy(update={'projectName': 'must not publish'}))
    monkeypatch.setattr(storage.os, 'replace', replace)
    assert store.load(project.projectId) == saved
    assert not list(store.project_dir(project.projectId).glob('.*.tmp'))


def test_conditional_http_saves_exports_and_recovery_copy(tmp_path):
    app = create_app(Config(data_dir=tmp_path))
    store = app.state.store
    project = stored_project(store)
    folder = store.project_dir(project.projectId)
    source_hash = hashlib.sha256((folder / project.source.asset).read_bytes()).hexdigest()
    with TestClient(app, base_url='http://localhost:8000') as client:
        endpoint = f'/api/projects/{project.projectId}'
        assert client.get('/api/capabilities').json()['conditionalSave'] is True
        assert client.get(endpoint).headers['etag'] == '"1"'
        draft = project.model_dump(mode='json')
        draft['projectName'] = 'my changes'
        assert client.put(endpoint, json=draft).status_code == 428
        assert client.post(endpoint + '/exports').status_code == 428
        assert client.put(endpoint, json=draft, headers={'If-Match': '"1"'}).json()['revision'] == 2
        stale = client.put(endpoint, json=project.model_dump(mode='json'), headers={'If-Match': '"1"'})
        assert stale.status_code == 412 and stale.json()['code'] == 'PROJECT_CONFLICT'
        assert stale.json()['currentRevision'] == 2
        assert client.post(endpoint + '/exports', headers={'If-Match': '"1"'}).status_code == 412
        draft['projectName'] = 'recover this'
        response = client.post(endpoint + '/recover-copy', json=draft)
        assert response.status_code == 200, response.text
        copy = Project.model_validate(response.json())
        assert copy.projectId != project.projectId and copy.revision == 1
        assert copy.annotations[0].id != project.annotations[0].id
        assert store.load(project.projectId).projectName == 'my changes'
        assert hashlib.sha256((store.project_dir(copy.projectId) / copy.source.asset).read_bytes()).hexdigest() == source_hash
        assert hashlib.sha256((folder / project.source.asset).read_bytes()).hexdigest() == source_hash
        copy.projectName = 'independent'
        store.save(copy)
        assert store.load(project.projectId).projectName == 'my changes'


def test_copy_failure_never_publishes_or_changes_original(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    import app.storage as storage
    monkeypatch.setattr(storage.shutil, 'copyfile', lambda *_args: (_ for _ in ()).throw(OSError('copy interrupted')))
    with pytest.raises(OSError):
        store.recover_copy(project)
    assert [p.name for p in store.root.iterdir()] == [project.projectId]
    assert store.load(project.projectId) == project
    unsafe = project.model_copy(deep=True)
    unsafe.source.asset = f'source/{uuid4()}.mp4'
    with pytest.raises(Exception, match='metadata'):
        store.recover_copy(unsafe)
