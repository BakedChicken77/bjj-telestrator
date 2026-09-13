"""Public package flow, immutable job input, leases and interrupted publication."""

import errno
import threading
from uuid import uuid4

import pytest
from test_media_jobs import media as media
from test_media_jobs import wait

from app.assets import digest_file
from app.errors import DomainError
from app.package_jobs import PackageJobs
from app.storage import ProjectStore, atomic_json


def create(client, operation, project=None, request_id=None):
    body = {"operation": operation, "requestId": request_id or str(uuid4()), "includeProxy": True}
    headers = {}
    if project:
        body["projectId"] = project.projectId
        headers["If-Match"] = f'"{project.revision}"'
    response = client.post('/api/package-jobs', json=body, headers=headers)
    assert response.status_code == 202, response.text
    return response.json()


def test_public_download_upload_restore_preserves_source_and_uses_saved_revision(media):
    app, client, project, source, _ = media
    manager, store = app.state.packages, app.state.store
    estimate = client.get(f'/api/projects/{project.projectId}/package-estimate').json()
    assert estimate['requiredBytes'] > estimate['outputBytes'] > source.stat().st_size
    job = create(client, 'backup', project)
    original_name = project.projectName
    saved = store.save(project.model_copy(update={'projectName': 'Edited after backup started'}))
    assert wait(manager, job['jobId']).status == 'completed'
    assert create(client, 'backup', project, job['jobId'])['jobId'] == job['jobId']
    response = client.get(f'/api/package-jobs/{job["jobId"]}/file')
    assert response.status_code == 200 and '.bjjproj' in response.headers['content-disposition']
    assert manager.readers[job['jobId']] == 0
    target = create(client, 'restore')
    upload = client.put(f'/api/package-jobs/{target["jobId"]}/content', content=response.content)
    assert upload.status_code == 202, upload.text
    result = wait(manager, target['jobId'])
    assert result.status == 'completed', result.error
    copy = store.load(result.projectId)
    assert copy.projectId != project.projectId and copy.revision == 1
    assert copy.projectName == original_name + ' (restored copy)'
    assert store.load(project.projectId).projectName == saved.projectName
    assert digest_file(store.project_dir(copy.projectId) / copy.source.asset) == digest_file(source)
    assert client.put(f'/api/package-jobs/{target["jobId"]}/content', content=response.content).status_code == 409
    assert manager.get(target['jobId']).status == 'completed'
    assert {j['jobId'] for j in client.get('/api/package-jobs').json()} == {job['jobId'], target['jobId']}
    assert client.delete(f'/api/package-jobs/{target["jobId"]}').status_code == 204
    assert store.load(copy.projectId).revision == 1


def test_package_download_lease_and_stale_request_cannot_remove_source(media):
    app, client, project, source, _ = media
    manager = app.state.packages
    job = create(client, 'backup', project)
    assert wait(manager, job['jobId']).status == 'completed'
    path = manager.acquire_output(job['jobId'])
    try:
        assert client.delete(f'/api/package-jobs/{job["jobId"]}').status_code == 409
        assert path.is_file()
    finally:
        manager.release_output(job['jobId'])
    assert client.delete(f'/api/package-jobs/{job["jobId"]}').status_code == 204
    assert not path.exists() and source.is_file()
    app.state.store.save(project.model_copy(update={'projectName': 'New revision'}))
    with pytest.raises(DomainError) as stale:
        manager.create('backup', str(uuid4()), project_id=project.projectId, revision=project.revision)
    assert stale.value.code == 'PROJECT_CONFLICT'


@pytest.mark.parametrize('failure', ['cancel', 'disk'])
def test_backup_failure_cleans_partial_and_releases_lease(media, monkeypatch, failure):
    import app.package_jobs as module
    app, client, project, source, _ = media
    entered, release = threading.Event(), threading.Event()
    real = module.backup
    def blocked(store, project, output, *args):
        entered.set()
        assert release.wait(5)
        if failure == 'disk':
            output.write_bytes(b'partial')
            raise OSError(errno.ENOSPC, 'injected low disk')
        return real(store, project, output, *args)
    monkeypatch.setattr(module, 'backup', blocked)
    manager = app.state.packages
    job = create(client, 'backup', project)
    assert entered.wait(5)
    assert app.state.store.leases[project.projectId] == 1
    if failure == 'cancel':
        assert client.post(f'/api/package-jobs/{job["jobId"]}/cancel').json()['cancelRequested']
    release.set()
    result = wait(manager, job['jobId'])
    assert result.errorCode == ('JOB_CANCELLED' if failure == 'cancel' else 'STORAGE_LOW')
    assert not manager.path(job['jobId'], 'backup.partial').exists()
    assert client.get(f'/api/package-jobs/{job["jobId"]}/file').status_code == 409
    assert digest_file(app.state.store.project_dir(project.projectId) / project.source.asset) == digest_file(source)


def test_restart_discards_only_incomplete_staging_and_retains_completed_receipt(media, monkeypatch):
    app, client, project, source, _ = media
    manager = app.state.packages
    real_persist = manager._persist
    def failed_record(job):
        if job.status == 'completed':
            raise OSError(errno.ENOSPC, 'injected status replacement failure')
        real_persist(job)
    monkeypatch.setattr(manager, '_persist', failed_record)
    job = create(client, 'backup', project)
    assert wait(manager, job['jobId']).status == 'completed'
    assert manager.path(job['jobId'], 'completed.json').is_file()
    pending = create(client, 'restore')
    staging = manager.path(pending['jobId'], 'staging')
    staging.mkdir()
    (staging / 'partial').write_bytes(b'incomplete package')
    manager.close()
    restarted = PackageJobs(app.state.store)
    try:
        assert restarted.get(job['jobId']).status == 'completed'
        assert restarted.acquire_output(job['jobId']).is_file()
        restarted.release_output(job['jobId'])
        assert restarted.get(pending['jobId']).errorCode == 'PACKAGE_INTERRUPTED'
        assert not staging.exists()
        assert digest_file(app.state.store.project_dir(project.projectId) / project.source.asset) == digest_file(source)
    finally:
        restarted.close()


def test_failed_creation_and_cancelled_upload_do_not_leave_stuck_jobs(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path)
    manager = PackageJobs(store)
    identifier = str(uuid4())
    try:
        with monkeypatch.context() as patch:
            patch.setattr(manager, '_persist', lambda _job: (_ for _ in ()).throw(OSError(errno.ENOSPC, 'full')))
            with pytest.raises(OSError):
                manager.create('restore', identifier)
        assert not manager.path(identifier, 'job.json').parent.exists()
        job = manager.create('restore', identifier)
        manager.cancel(job.jobId)
        with pytest.raises(DomainError):
            manager.begin_upload(job.jobId)
        assert manager.get(job.jobId).status == 'cancelled'
        # An untrusted job record cannot authorize traversal on the next launch.
        bad_id = str(uuid4())
        bad = job.model_dump(mode='json')
        bad.update(jobId=bad_id, projectId='../protected', status='running')
        atomic_json(manager.path(bad_id, 'job.json'), bad)
    finally:
        manager.close()
    restarted = PackageJobs(store)
    try:
        with pytest.raises(DomainError):
            restarted.get(bad_id)
    finally:
        restarted.close()
