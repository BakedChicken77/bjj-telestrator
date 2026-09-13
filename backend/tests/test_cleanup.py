import os
import time
from uuid import uuid4

import pytest
from test_media_jobs import media as media

from app.assets import digest_file
from app.cleanup import GRACE_SECONDS, preview_cleanup
from app.errors import DomainError
from app.storage import atomic_json


def test_cleanup_preserves_live_recovery_leases_and_grace_period(media):
    app, client, project, source, _ = media
    store = app.state.store
    folder = store.project_dir(project.projectId)
    paths = []
    for _ in range(4):
        path = folder / 'proxy' / f'{uuid4()}.mp4'
        path.write_bytes(b'generated obsolete preview')
        os.utime(path, (time.time() - 2 * GRACE_SECONDS,) * 2)
        paths.append(path)
    os.utime(paths[1], None)  # New unreferenced preview remains under grace.
    atomic_json(folder / 'checkpoints' / f'{uuid4()}.json', {'version': 1, 'input': {'project': {'proxy': {'asset': f'proxy/{paths[2].name}'}}}})
    atomic_json(folder / 'recovery' / f'{uuid4()}.json', {'version': 1, 'project': {'proxy': {'asset': f'proxy/{paths[3].name}'}}})
    (folder / 'project.index.json').write_bytes(b'broken disposable summary')
    assert preview_cleanup(store, project.projectId)['files'] == 1
    store.acquire_lease(project.projectId)
    try:
        assert client.post(f'/api/projects/{project.projectId}/derived-cleanup', headers={'If-Match': f'"{project.revision}"'}).status_code == 409
        assert all(path.exists() for path in paths)
    finally:
        store.release_lease(project.projectId)
    result = client.post(f'/api/projects/{project.projectId}/derived-cleanup', headers={'If-Match': f'"{project.revision}"'})
    assert result.status_code == 200 and result.json()['files'] == 1
    assert not paths[0].exists() and all(path.exists() for path in paths[1:])
    assert digest_file(folder / project.source.asset) == digest_file(source)
    assert (folder / project.proxy.asset).exists()
    assert store.load(project.projectId).revision == project.revision


def test_cleanup_refuses_corrupt_metadata_and_stale_revision(media):
    app, client, project, _, _ = media
    store = app.state.store
    folder = store.project_dir(project.projectId)
    (folder / 'retained-recovery.json').write_text('{broken')
    with pytest.raises(DomainError) as error:
        preview_cleanup(store, project.projectId, project.revision, remove=True)
    assert error.value.code == 'CLEANUP_BLOCKED'
    assert 'cleanupBlocked' in client.get(f'/api/projects/{project.projectId}/storage').json()
    with pytest.raises(DomainError) as error:
        preview_cleanup(store, project.projectId, project.revision + 1, remove=True)
    assert error.value.code == 'PROJECT_CONFLICT'


def test_stale_draft_recovers_with_service_resolved_repaired_proxy(media):
    app, _, project, _, _ = media
    store = app.state.store
    folder = store.project_dir(project.projectId)
    old = folder / project.proxy.asset
    replacement = folder / 'proxy' / f'{uuid4()}.mp4'
    replacement.write_bytes(old.read_bytes())
    proxy = project.proxy.model_copy(update={'asset': f'proxy/{replacement.name}'})
    store.save(project.model_copy(update={'proxy': proxy}), replacing_proxy=True)
    old.unlink()
    recovered = store.recover_copy(project.model_copy(update={'projectName': 'Unsaved coaching edits'}))
    assert recovered.projectName.startswith('Unsaved coaching edits')
    assert recovered.proxy.asset == proxy.asset and recovered.projectId != project.projectId
