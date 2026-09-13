"""Real media repair plus bounded failure injection around publication/cancel."""
from __future__ import annotations

import errno
import subprocess
import threading
import time

import pytest
from fastapi.testclient import TestClient

from app.assets import digest_file
from app.config import Config
from app.errors import DomainError
from app.main import create_app
from app.media import parse_probe, probe_media, require_sdr
from app.media_jobs import MediaJobs
from app.models import Project
from app.storage import ProjectStore, StorageError, atomic_json
from test_backend import raw_project


@pytest.fixture
def media(tmp_path):
    path = tmp_path / 'source.mov'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=160x120:r=60:d=2.2',
                    '-itsoffset', '0.2', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
                    '-c:v', 'libx264', '-threads', '2', '-pix_fmt', 'yuv420p', '-c:a', 'aac', str(path)], check=True)
    app = create_app(Config(data_dir=tmp_path / 'data'))
    with TestClient(app, base_url='http://localhost:8000') as client:
        job = client.post('/api/import-jobs').json()
        with path.open('rb') as source:
            response = client.post('/api/projects/import', files={'file': ('source.mov', source, 'video/quicktime')},
                                   headers={'X-BJJ-Import-ID': job['jobId']})
        assert response.status_code == 200, response.text
        yield app, client, Project.model_validate(response.json()), path, job


def wait(manager, job_id):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        job = manager.get(job_id)
        if job.status in ('failed', 'completed', 'cancelled'):
            # Terminal publication precedes finally cleanup by a few instructions.
            if manager.store.leases.get(job.projectId, 0) == 0:
                return job
        time.sleep(.01)
    pytest.fail(f'Media operation did not settle: {manager.get(job_id)}')


def test_tracked_import_and_missing_proxy_repair_preserve_edits_source_and_audio(media):
    app, client, project, source, job = media
    store, manager = app.state.store, app.state.media
    progress = client.get(f'/api/media-jobs/{job["jobId"]}').json()
    assert progress['status'] == 'completed' and progress['stage'] == 'ready'
    assert progress['copiedBytes'] == progress['totalBytes'] == source.stat().st_size
    assert project.source.avgFrameRate == 60 and project.proxy.avgFrameRate == 30
    doc = project.model_dump(mode='json')
    cue = raw_project()['annotations'][0]
    cue.update(startSec=.5, endSec=1.5)
    doc['annotations'] = [cue]
    old_proxy = store.project_dir(project.projectId) / project.proxy.asset
    old_proxy.unlink()  # Pending edits must save before a missing-preview repair.
    saved = store.save(Project.model_validate(doc))
    before = saved.model_dump(mode='json')
    with pytest.raises(StorageError):
        store.save(saved, replacing_proxy=True)  # A replacement cannot publish missing bytes.
    response = client.post(f'/api/projects/{saved.projectId}/proxy-jobs', headers={'If-Match': f'"{saved.revision}"'})
    assert response.status_code == 202
    result = wait(manager, response.json()['jobId'])
    assert result.status == 'completed', result.error
    repaired = store.load(saved.projectId)
    assert repaired.revision == saved.revision + 1 and repaired.proxy.asset != saved.proxy.asset
    after = repaired.model_dump(mode='json')
    for key in before.keys() - {'proxy', 'revision', 'updatedAt'}:
        assert after[key] == before[key], key
    path = store.project_dir(saved.projectId) / repaired.proxy.asset
    assert digest_file(store.project_dir(saved.projectId) / repaired.source.asset) == digest_file(source)
    probe = probe_media(path, repaired.proxy.asset, 'preview.mp4')
    assert probe.durationSec == pytest.approx(2.2, abs=1/30)
    assert probe.hasAudio and probe.audioCodec == 'aac' and probe.avgFrameRate == 30
    assert not old_proxy.exists()
    assert client.put(f'/api/projects/{saved.projectId}', json=before, headers={'If-Match': f'"{saved.revision}"'}).status_code == 412
    assert not list((store.project_dir(saved.projectId) / 'temp').glob('media-*'))
    print(f'P1.04 desktop repair: h264/aac 160x120 30fps duration={probe.durationSec} bytes={path.stat().st_size} source_sha256={digest_file(source)}')


@pytest.mark.parametrize('action', ['cancel', 'stale', 'storage'])
def test_failed_or_cancelled_repair_never_replaces_current_preview(media, monkeypatch, action):
    import app.media_jobs as module
    app, _client, original, _source, _job = media
    store, manager = app.state.store, app.state.media
    old = store.project_dir(original.projectId) / original.proxy.asset
    old_hash = digest_file(old)
    entered, release = threading.Event(), threading.Event()
    encoder = module.create_proxy
    def blocked(source, target, metadata, cancel, progress):
        target.write_bytes(b'injected partial derived media')
        entered.set()
        assert release.wait(5), 'failure-injection release was not signaled'
        if action == 'storage':
            raise OSError(errno.ENOSPC, 'injected full storage')
        encoder(source, target, metadata, cancel, progress)
    monkeypatch.setattr(module, 'create_proxy', blocked)
    job = manager.repair(original.projectId, original.revision)
    assert entered.wait(5)
    assert manager.get(job.jobId).stage == 'preparing_preview'
    assert store.leases[original.projectId] == 1
    if action == 'cancel':
        assert manager.cancel(job.jobId).cancelRequested
    if action == 'stale':
        store.save(original.model_copy(update={'projectName': 'Other tab saved'}))
    release.set()
    result = wait(manager, job.jobId)
    assert result.errorCode == {'cancel': 'JOB_CANCELLED', 'stale': 'PROJECT_CONFLICT', 'storage': 'STORAGE_LOW'}[action]
    current = store.load(original.projectId)
    assert current.proxy == original.proxy and digest_file(old) == old_hash
    assert current.projectName == ('Other tab saved' if action == 'stale' else original.projectName)
    assert not list(old.parent.parent.joinpath('temp').glob('media-*'))


def test_media_jobs_restart_rejects_unsafe_records_and_discards_only_uncommitted_import(tmp_path):
    store = ProjectStore(tmp_path)
    manager = MediaJobs(store)
    job = manager.create()
    folder = manager.begin_import(job.jobId)
    (folder / 'source/partial.mov').write_bytes(b'partial source staging')
    manager.close()
    # Restart recovery owns generated job/project UUIDs; never an arbitrary JSON path.
    bad = job.model_dump()
    bad['projectId'] = '../outside'
    atomic_json(manager.root / 'bad.json', {'version': 1, 'job': bad})
    restarted = MediaJobs(store)
    try:
        assert restarted.get(job.jobId).errorCode == 'MEDIA_INTERRUPTED'
        assert not folder.exists()
        assert (manager.root / 'bad.json').exists()
        with pytest.raises(StorageError):
            restarted.get('../outside')
    finally:
        restarted.close()


def test_unsafe_repair_staging_fails_without_leaking_project_lease(media, tmp_path):
    app, _client, original, _source, _job = media
    store, manager = app.state.store, app.state.media
    temporary = store.project_dir(original.projectId) / 'temp'
    temporary.rmdir()
    outside = tmp_path / 'outside'
    outside.mkdir()
    protected = outside / 'retained.txt'
    protected.write_text('must remain')
    try:
        temporary.symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip('This filesystem cannot create test symlinks')
    try:
        job = manager.repair(original.projectId, original.revision)
        assert wait(manager, job.jobId).status == 'failed'
        assert store.leases.get(original.projectId, 0) == 0
        assert store.load(original.projectId) == original
        assert protected.read_text() == 'must remain'
    finally:
        temporary.unlink()
        temporary.mkdir()


@pytest.mark.parametrize('transfer', ['smpte2084', 'arib-std-b67'])
def test_hdr_metadata_is_not_confused_with_sdr_hevc(transfer):
    stream = {'codec_type': 'video', 'codec_name': 'hevc', 'width': 160, 'height': 120, 'duration': '2',
              'avg_frame_rate': '30000/1001', 'r_frame_rate': '60000/1001', 'time_base': '1/90000',
              'color_transfer': transfer, 'color_primaries': 'bt2020', 'color_space': 'bt2020nc', 'color_range': 'tv'}
    hdr = parse_probe({'streams': [stream]}, 'source/test.mov', 'test.mov')
    assert hdr.transferFunction == transfer and hdr.averageFrameRateRational == '30000/1001'
    assert hdr.timeBase == '1/90000' and hdr.colorPrimaries == 'bt2020'
    with pytest.raises(DomainError) as failure:
        require_sdr(hdr)
    assert failure.value.code == 'MEDIA_UNSUPPORTED'
    sdr = parse_probe({'streams': [{**stream, 'color_transfer': 'bt709', 'color_primaries': 'bt709'}]}, 'source/test.mov', 'test.mov')
    require_sdr(sdr)


def test_unused_cancelled_import_and_duplicate_request_cannot_damage_existing_job(media):
    app, client, _project, source, existing = media
    unused = client.post('/api/import-jobs').json()
    cancelled = client.delete(f'/api/media-jobs/{unused["jobId"]}').json()
    assert cancelled['status'] == 'cancelled'
    with source.open('rb') as handle:
        response = client.post('/api/projects/import', files={'file': ('test.mov', handle, 'video/quicktime')}, headers={'X-BJJ-Import-ID': unused['jobId']})
    assert response.status_code == 409
    with source.open('rb') as handle:
        duplicate = client.post('/api/projects/import', files={'file': ('test.mov', handle, 'video/quicktime')}, headers={'X-BJJ-Import-ID': existing['jobId']})
    assert duplicate.status_code == 409
    assert client.get(f'/api/media-jobs/{existing["jobId"]}').json()['status'] == 'completed'
    repair = app.state.media.create(_project)
    with source.open('rb') as handle:
        wrong_operation = client.post('/api/projects/import', files={'file': ('test.mov', handle, 'video/quicktime')}, headers={'X-BJJ-Import-ID': repair.jobId})
    assert wrong_operation.status_code == 409
    assert app.state.media.get(repair.jobId).status == 'queued'
    app.state.media.cancel(repair.jobId)
    assert len(app.state.store.list()) == 1


def test_real_ffmpeg_preparation_can_be_cancelled_after_encoder_progress(media, monkeypatch):
    import app.media as module
    app, _client, project, source, _job = media
    args = module.proxy_args
    def paced(*values):
        command = args(*values)
        command.insert(command.index('-i'), '-re')  # Pace this fixture's decoder, not a shipped setting.
        return command
    monkeypatch.setattr(module, 'proxy_args', paced)
    cancelled = threading.Event()
    observed = []
    def progress(seconds):
        observed.append(seconds)
        cancelled.set()
    target = app.state.store.project_dir(project.projectId) / 'temp/cancel.mp4'
    before = digest_file(source)
    with pytest.raises(DomainError) as failure:
        module.create_proxy(source, target, project.source, cancelled, progress)
    assert failure.value.code == 'JOB_CANCELLED' and observed
    assert not target.exists() and not target.with_suffix('.ffmpeg.log').exists()
    assert digest_file(source) == before
