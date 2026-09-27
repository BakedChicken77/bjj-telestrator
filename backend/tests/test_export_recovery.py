"""Immutable retry, retention, failure injection and real MP4 evidence."""
from __future__ import annotations

import errno
import hashlib
import json
import os
import shutil
import subprocess
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.assets import digest_file, export_estimate, manifest_assets, require_space, storage_summary
from app.config import Config
from app.errors import DomainError
from app.jobs import JobManager
from app.main import create_app
from app.media import probe_media
from app.render_plan import build_plan, validate_plan, verify_assets
from app.storage import ProjectStore, atomic_json
from test_backend import stored_project, wait_job

FIXTURES = json.loads((Path(__file__).parents[2] / 'tests/fixtures/export-plan-conformance.json').read_text())


def fake_output(_project, _folder, output, _temp, _progress, _event):
    output.write_bytes(b'isolated job lifecycle fake')


def isolated(store, **kwargs):
    return JobManager(store, renderer=fake_output, validator=lambda _path, _project: None, **kwargs)


@pytest.mark.parametrize('case', FIXTURES['cases'], ids=lambda item: item['name'])
def test_cross_platform_export_input_conformance(case):
    plan = case['plan']
    if case['valid']:
        assert validate_plan(plan, '11111111-1111-4111-8111-111111111111', 1).revision == 1
    else:
        with pytest.raises((ValueError, KeyError, TypeError)):
            validate_plan(plan, '11111111-1111-4111-8111-111111111111', 1)


def test_incremental_cached_hash_and_changed_source_rejection(tmp_path, monkeypatch):
    import app.assets as assets
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    path = store.project_dir(project.projectId) / project.source.asset
    content = b'chunked source' * 200_000
    path.write_bytes(content)
    hashes = []
    original = assets.digest_file
    monkeypatch.setattr(assets, 'digest_file', lambda path: (hashes.append(path), original(path))[1])
    first = manifest_assets(store, project)
    assert first[0]['sha256'] == hashlib.sha256(content).hexdigest()
    assert first[0]['byteSize'] == len(content)
    assert manifest_assets(store, store.save(project)) == first
    assert len(hashes) == 1  # Autosave neither hashes nor rewrites asset identity.
    stamp = path.stat()
    path.write_bytes(b'X' + content[1:])
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    with pytest.raises(DomainError, match='changed'):
        manifest_assets(store, project)
    plan = {'assets': first}
    with pytest.raises(DomainError, match='differs'):
        verify_assets(path.parent.parent, plan)
    path.write_bytes(content)
    assert manifest_assets(store, project) == first
    cancelled = threading.Event()
    cancelled.set()
    from app.renderer import ExportCancelled
    with pytest.raises(ExportCancelled):
        digest_file(path, cancelled)


def test_asset_symlink_is_never_hashed(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    folder = store.project_dir(project.projectId)
    source = folder / project.source.asset
    source.unlink()
    source.symlink_to(folder / project.proxy.asset)
    with pytest.raises(DomainError) as result:
        build_plan(store, project)
    assert result.value.code == 'ASSET_UNSAFE'


def test_restart_retry_uses_old_revision_and_cleanup_keeps_inputs(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    manager = isolated(store)
    first = manager.create(project)
    assert wait_job(manager, first.jobId) == 'completed'
    manager.close()
    original_input = manager.input_path(first).read_bytes()
    saved = store.save(project.model_copy(update={'projectName': 'New edit', 'annotations': []}))
    # Simulate process death with a durable input and an incomplete output.
    first.status = 'running'
    atomic_json(manager.input_path(first).parent.parent / f'{first.jobId}.json', first.model_dump())
    recovered = isolated(ProjectStore(tmp_path))
    interrupted = recovered.get(first.jobId)
    assert interrupted.status == 'failed' and interrupted.errorCode == 'EXPORT_INTERRUPTED'
    assert not recovered.output_path(first).exists()
    retried = recovered.retry(first.jobId)
    assert wait_job(recovered, retried.jobId) == 'completed'
    assert retried.projectRevision == project.revision < saved.revision
    assert retried.retryOf == first.jobId and retried.jobId != first.jobId
    assert recovered.input_path(retried).read_bytes() == original_input
    assert store.load(project.projectId) == saved
    recovered.close()
    job, _ = recovered.acquire_output(retried.jobId)
    with pytest.raises(DomainError):
        recovered.remove_output(job.jobId)
    with pytest.raises(DomainError):
        recovered.store.delete(project.projectId)
    recovered.release_output(job)
    assert recovered.remove_output(job.jobId).outputAvailable is False
    assert not recovered.output_path(job).exists()
    assert recovered.input_path(job).read_bytes() == original_input
    assert (store.project_dir(project.projectId) / project.source.asset).read_bytes() == b'source'
    assert storage_summary(store, saved)['exportBytes'] == 0


def test_low_space_and_atomic_input_failure_publish_no_job(tmp_path, monkeypatch):
    import app.assets as assets
    import app.jobs as jobs
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    manager = isolated(store)
    estimate = export_estimate(project)
    assert estimate['workingBytes'] >= 1920 * 1080 * 4 * 3
    assert estimate['requiredBytes'] > estimate['outputBytes'] + estimate['workingBytes']
    with monkeypatch.context() as patch:
        patch.setattr(assets.shutil, 'disk_usage', lambda _path: SimpleNamespace(free=0))
        with pytest.raises(DomainError) as result:
            manager.create(project)
        assert result.value.code == 'STORAGE_LOW'
        assert manager.list(project.projectId) == [] and not store.leases[project.projectId]
    with monkeypatch.context() as patch:
        patch.setattr(jobs, 'atomic_json', lambda *_args: (_ for _ in ()).throw(OSError(errno.ENOSPC, 'injected')))
        with pytest.raises(OSError):
            manager.create(project)
        assert manager.list(project.projectId) == [] and not store.leases[project.projectId]
    manager.close()
    assert store.load(project.projectId) == project
    assert not list((store.project_dir(project.projectId) / 'exports').glob('*.json'))
    require_space(store.root, estimate)


def test_validation_and_changed_asset_never_publish_partial_output(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    # Real validation must reject a fake encoder's non-MP4 bytes.
    manager = JobManager(store, renderer=fake_output)
    job = manager.create(project)
    assert wait_job(manager, job.jobId) == 'failed'
    assert not manager.output_path(job).exists()
    assert manager.get(job.jobId).retryAvailable
    manager.close()
    path = store.project_dir(project.projectId) / project.source.asset
    path.write_bytes(b'CHANGED')
    manager = isolated(store)
    retry = manager.retry(job.jobId)
    assert wait_job(manager, retry.jobId) == 'failed'
    assert manager.get(retry.jobId).errorCode == 'ASSET_CHANGED'
    assert not manager.output_path(retry).exists()
    manager.close()
    assert not list((path.parent.parent / 'temp').iterdir())


def test_http_storage_retry_and_safe_cleanup(tmp_path):
    app = create_app(Config(data_dir=tmp_path))
    project = stored_project(app.state.store)
    with TestClient(app, base_url='http://localhost:8000') as client:
        app.state.jobs.renderer = fake_output
        app.state.jobs.validator = lambda _path, _project: None
        assert client.get('/api/capabilities').json()['exportRetry']
        storage = client.get(f'/api/projects/{project.projectId}/storage').json()
        assert storage['sourceBytes'] == 6 and storage['proxyBytes'] == 5
        first = client.post(f'/api/projects/{project.projectId}/exports', headers={'If-Match': '"1"'}).json()
        assert wait_job(app.state.jobs, first['jobId']) == 'completed'
        assert client.get(f"/api/exports/{first['jobId']}/download").status_code == 200
        response = client.delete(f"/api/exports/{first['jobId']}/file")
        assert response.status_code == 200 and response.json()['outputAvailable'] is False
        assert client.get(f"/api/exports/{first['jobId']}/download").status_code == 409
        again = client.post(f"/api/exports/{first['jobId']}/retry").json()
        assert again['projectRevision'] == 1 and again['retryOf'] == first['jobId']
        assert client.post('/api/exports/not-a-uuid/retry').status_code == 400
        assert client.delete('/api/exports/not-a-uuid/file').status_code == 400


@pytest.mark.integration
def test_real_mp4_retry_after_restart_keeps_old_pixels_and_hash(tmp_path):
    from test_renderer import sample_frame
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    folder = store.project_dir(project.projectId)
    source = folder / project.source.asset
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=black:s=320x180:r=30:d=4',
                    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(source)], check=True)
    media = probe_media(source, project.source.asset, 'generated.mp4')
    shutil.copyfile(source, folder / project.proxy.asset)
    document = project.model_dump(mode='json')
    document.update(source=media.model_dump(mode='json'), proxy={**media.model_dump(mode='json'), 'asset': project.proxy.asset})
    document['annotations'][0].update(startSec=1, endSec=2, strokeWidth=.025)
    # Fixture installation, before any user mutation or export inventory exists.
    atomic_json(folder / 'project.json', document)
    project = store.load(project.projectId)
    before = digest_file(source)
    manager = JobManager(store)
    first = manager.create(project)
    assert wait_job(manager, first.jobId) == 'completed'
    manager.close()
    saved = store.save(project.model_copy(update={'annotations': []}))
    manager = JobManager(ProjectStore(tmp_path))
    retry = manager.retry(first.jobId)
    assert wait_job(manager, retry.jobId) == 'completed'
    manager.close()
    result = probe_media(manager.output_path(retry), 'exports/result.mp4', 'result.mp4')
    assert (result.codec, result.hasAudio, result.displayWidth, result.displayHeight) == ('h264', False, 320, 180)
    assert result.durationSec == pytest.approx(4, abs=.1)
    # Independent red-pixel test on a black source; the current project has no cues.
    for time, visible in [(0.9, False), (1, True), (1.9, True), (2, False)]:
        pixels = sample_frame(manager.output_path(retry), round(time * 30), 320, 180).tobytes()
        red = sum(pixels[i] > 140 and pixels[i + 1] < 90 and pixels[i + 2] < 90 for i in range(0, len(pixels), 3))
        assert (red > 100) == visible
    assert saved.annotations == [] and store.load(project.projectId).revision == saved.revision
    assert digest_file(source) == before
    print(f'P1.06 real retry: h264 silent 320x180 bytes={manager.output_path(retry).stat().st_size} duration={result.durationSec} source_sha256={before}')


def test_input_symlink_cannot_escape_and_releases_preparation_lease(tmp_path):
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    outside = tmp_path / 'outside'
    outside.mkdir()
    (store.project_dir(project.projectId) / 'exports' / 'inputs').symlink_to(outside, target_is_directory=True)
    manager = isolated(store)
    from app.storage import StorageError
    with pytest.raises(StorageError):
        manager.create(project)
    assert list(outside.iterdir()) == []
    assert not store.leases[project.projectId]
    assert manager.list(project.projectId) == []
    manager.close()


def test_cleanup_old_output_while_new_render_runs_and_disk_fills(tmp_path, monkeypatch):
    import app.jobs as jobs
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    manager = isolated(store)
    first = manager.create(project)
    assert wait_job(manager, first.jobId) == 'completed'
    entered, release = threading.Event(), threading.Event()

    def hold(_project, _folder, output, _temp, _progress, _event):
        entered.set()
        assert release.wait(3)
        output.write_bytes(b'partial fake awaiting finalization')

    manager.renderer = hold
    second = manager.create(project)
    assert entered.wait(3)
    assert manager.remove_output(first.jobId).outputAvailable is False
    assert manager.input_path(first).exists() and manager.input_path(second).exists()
    with pytest.raises(DomainError):
        manager.remove_output(second.jobId)
    with pytest.raises(DomainError):
        store.delete(project.projectId)
    replace = jobs.os.replace

    def disk_full(source, destination):
        if Path(destination).suffix == '.mp4':
            raise OSError(errno.ENOSPC, 'injected atomic finalization failure')
        return replace(source, destination)

    monkeypatch.setattr(jobs.os, 'replace', disk_full)
    release.set()
    assert wait_job(manager, second.jobId) == 'failed'
    assert manager.get(second.jobId).errorCode == 'STORAGE_LOW'
    manager.close()
    assert not manager.output_path(second).exists()
    assert not list((store.project_dir(project.projectId) / 'temp').iterdir())
    assert (store.project_dir(project.projectId) / project.source.asset).read_bytes() == b'source'
