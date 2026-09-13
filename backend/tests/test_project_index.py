"""The disposable library index never replaces project validation or durable saves."""
from __future__ import annotations

import json
from pathlib import Path
from uuid import uuid4

import pytest

from app import storage
from app.errors import DomainError
from app.storage import ProjectStore, atomic_json
from test_backend import stored_project


def test_unchanged_library_reopens_without_loading_full_timelines(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path)
    original = stored_project(store)
    restarted = ProjectStore(tmp_path)
    monkeypatch.setattr(restarted, 'load', lambda _: pytest.fail('Unchanged index loaded a full timeline'))
    assert restarted.list() == [{
        'projectId': original.projectId, 'projectName': original.projectName,
        'updatedAt': original.updatedAt, 'durationSec': 20.0,
        'annotationCount': 1, 'revision': 1}]


@pytest.mark.parametrize('damage', ['missing', 'broken', 'oversize', 'foreign_id', 'invalid_count', 'future_cache'])
def test_bad_index_rebuilds_without_changing_project_or_source(tmp_path, damage):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    folder = store.project_dir(project.projectId)
    path = folder / 'project.index.json'
    original = (folder / 'project.json').read_bytes()
    index = json.loads(path.read_bytes())
    if damage == 'missing':
        path.unlink()
    elif damage == 'broken':
        path.write_bytes(b'broken')
    elif damage == 'oversize':
        path.write_bytes(b' ' * 8193)
    else:
        if damage == 'foreign_id':
            index['summary']['projectId'] = str(uuid4())
        elif damage == 'invalid_count':
            index['summary']['annotationCount'] = True
        else:
            index['schemaVersion'] = 99
        atomic_json(path, index)
    assert store.list()[0]['annotationCount'] == 1
    assert json.loads(path.read_bytes())['summary']['projectId'] == project.projectId
    assert (folder / 'project.json').read_bytes() == original
    assert (folder / project.source.asset).read_bytes() == b'source'


@pytest.mark.parametrize(('field', 'value', 'code'), [
    ('schemaVersion', 99, 'SCHEMA_UNSUPPORTED'),
    ('requiredCapabilities', ['project.revisions.v1', 'unknown.required'], 'CAPABILITY_UNSUPPORTED'),
    ('annotations', [{'bad': 'cue'}], 'PROJECT_CORRUPT'),
])
def test_replaced_document_invalidates_index_and_still_blocks_open(tmp_path, field, value, code):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    path = store.project_dir(project.projectId) / 'project.json'
    document = json.loads(path.read_bytes())
    document[field] = value
    atomic_json(path, document)
    assert store.list()[0]['unavailableCode'] == code
    with pytest.raises(DomainError) as error:
        store.load(project.projectId)
    assert error.value.code == code


def test_index_write_failure_does_not_report_a_committed_save_as_failed(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    write = storage.atomic_json

    def fail_index(path, value):
        if path.name == 'project.index.json':
            raise OSError('Injected full disk during optional cache write')
        write(path, value)

    monkeypatch.setattr(storage, 'atomic_json', fail_index)
    saved = store.save(project.model_copy(update={'projectName': 'Changed name'}))
    assert saved.revision == 2
    restarted = ProjectStore(tmp_path)
    assert restarted.load(project.projectId).projectName == 'Changed name'
    assert restarted.list()[0]['projectName'] == 'Changed name'
    assert restarted.list()[0]['revision'] == 2


def test_symlink_index_is_never_followed_or_written(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    path = store.project_dir(project.projectId) / 'project.index.json'
    outside = tmp_path / 'outside.json'
    outside.write_bytes(b'keep this file')
    path.unlink()
    try:
        path.symlink_to(outside)
    except OSError:
        pytest.skip('This host cannot create symbolic links')
    assert store.list()[0]['projectId'] == project.projectId
    assert outside.read_bytes() == b'keep this file'


def test_normal_save_refreshes_summary_and_returns_no_asset_paths(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    saved = store.save(project.model_copy(update={'projectName': 'Revisão', 'annotations': []}))
    summary = store.list()[0]
    assert summary['projectName'] == 'Revisão'
    assert summary['revision'] == saved.revision == 2
    assert summary['annotationCount'] == 0
    assert not any(isinstance(value, (list, dict, Path)) for value in summary.values())
