"""Persistence, API safety, metadata, and tracked lifecycle tests."""
from __future__ import annotations

import array
import hashlib
import math
import subprocess
import threading
import time
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.config import Config
from app.errors import DomainError
from app.jobs import JobManager
from app.main import create_app
from app.media import MediaError, parse_probe, probe_media, proxy_args, proxy_dimensions
from app.models import Project
from app.renderer import ExportCancelled
from app.storage import ProjectStore, StorageError, asset_path, atomic_json, require_uuid, safe_filename

STAMP = '2026-09-05T00:00:00Z'


def raw_project(project_id: str | None = None) -> dict:
    media = {'asset': 'source/original.mp4', 'originalFilename': 'original.mp4', 'durationSec': 20,
             'codec': 'h264', 'audioCodec': 'aac', 'hasAudio': True, 'codedWidth': 1920,
             'codedHeight': 1080, 'displayWidth': 1920, 'displayHeight': 1080,
             'sampleAspectRatio': '1:1', 'displayAspectRatio': '16:9', 'rotation': 0, 'avgFrameRate': 30}
    return {'schemaVersion': 1, 'projectId': project_id or str(uuid4()), 'projectName': 'Test',
            'createdAt': STAMP, 'updatedAt': STAMP, 'source': media,
            'proxy': {**media, 'asset': 'proxy/editing.mp4'}, 'settings': {}, 'exportSettings': {},
            'annotations': [{'id': str(uuid4()), 'type': 'arrow', 'startSec': 5, 'endSec': 10,
                             'zIndex': 0, 'strokeColor': '#ff0000', 'strokeWidth': .006, 'strokeOpacity': 1,
                             'fillColor': '#ff0000', 'fillOpacity': 0,
                             'geometry': {'x1': .2, 'y1': .3, 'x2': .6, 'y2': .5, 'arrowheadSize': .025},
                             'createdAt': STAMP, 'updatedAt': STAMP}], 'voiceovers': []}


def stored_project(store: ProjectStore) -> Project:
    project = Project.model_validate(raw_project())
    directory = store.create_dir(project.projectId)
    (directory / project.source.asset).write_bytes(b'source')
    (directory / project.proxy.asset).write_bytes(b'proxy')
    return store.save(project, existing=False)


@pytest.mark.parametrize('mutation', ['negative', 'zero', 'past', 'geometry', 'color', 'nan', 'ids', 'version'])
def test_document_rejects_invalid(mutation: str) -> None:
    document = raw_project()
    annotation = document['annotations'][0]
    if mutation == 'negative':
        annotation['startSec'] = -1
    elif mutation == 'zero':
        annotation['endSec'] = annotation['startSec']
    elif mutation == 'past':
        annotation['endSec'] = 20.01
    elif mutation == 'geometry':
        annotation['geometry']['x2'] = 1.1
    elif mutation == 'color':
        annotation['strokeColor'] = 'red; command'
    elif mutation == 'nan':
        annotation['strokeWidth'] = math.nan
    elif mutation == 'ids':
        document['annotations'].append(annotation.copy())
    else:
        document['schemaVersion'] = 99
    with pytest.raises(ValidationError):
        Project.model_validate(document)


def test_unknown_fields_and_all_geometry_round_trip() -> None:
    document = raw_project()
    document['futureProjectField'] = {'keep': True}
    document['settings']['futureSetting'] = 'keep'
    document['annotations'][0]['geometry']['futureGeometry'] = [1, 2]
    parsed = Project.model_validate(document).model_dump()
    assert parsed['futureProjectField'] == {'keep': True}
    assert parsed['settings']['futureSetting'] == 'keep'
    assert parsed['annotations'][0]['geometry']['futureGeometry'] == [1, 2]


@pytest.mark.parametrize('path', ['../outside', '/etc/passwd', 'C:/video.mp4', 'source/../../x', 'source\\x', 'source//x'])
def test_path_safety(tmp_path: Path, path: str) -> None:
    with pytest.raises(StorageError):
        asset_path(tmp_path, path)
    with pytest.raises(StorageError):
        require_uuid(path)


def test_symlink_escape(tmp_path: Path) -> None:
    project = tmp_path / 'project'
    project.mkdir()
    (project / 'escape').symlink_to(tmp_path, target_is_directory=True)
    with pytest.raises(StorageError):
        asset_path(project, 'escape/stolen.mp4')


def test_sanitization_atomic_storage_and_restart(tmp_path: Path) -> None:
    assert safe_filename('../../a;$(bad).mp4') == 'a___bad_.mp4'
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    project.projectName = 'Saved name'
    saved = store.save(project)
    assert saved.projectName == 'Saved name'
    assert ProjectStore(tmp_path).load(project.projectId).projectName == 'Saved name'
    assert not list(store.project_dir(project.projectId).glob('*.tmp'))
    project.source.asset = 'source/other.mp4'
    with pytest.raises(StorageError, match='cannot be changed'):
        store.save(project)
    path = store.project_dir(project.projectId) / 'project.json'
    path.write_text('{bad', encoding='utf-8')
    with pytest.raises(DomainError, match='damaged'):
        store.load(project.projectId)
    assert store.list()[0]['unavailableCode'] == 'PROJECT_CORRUPT'


def probe_document(rotation: float = 0) -> dict:
    return {'streams': [{'index': 0, 'codec_type': 'video', 'codec_name': 'mjpeg', 'width': 20,
                         'height': 20, 'disposition': {'attached_pic': 1}},
                        {'index': 2, 'codec_type': 'video', 'codec_name': 'hevc', 'width': 1920,
                         'height': 1080, 'sample_aspect_ratio': '4:3', 'display_aspect_ratio': '64:27',
                         'duration': '20', 'start_time': '0.2', 'avg_frame_rate': '30000/1001',
                         'side_data_list': [{'rotation': rotation}]},
                        {'index': 3, 'codec_type': 'audio', 'codec_name': 'aac'}],
            'format': {'duration': '20.3'}}


@pytest.mark.parametrize('rotation,dimensions', [(0, (2560, 1080)), (90, (1080, 2560)), (-90, (1080, 2560)), (180, (2560, 1080))])
def test_rotation_sar_and_stream_selection(rotation: float, dimensions: tuple[int, int]) -> None:
    metadata = parse_probe(probe_document(rotation), 'source/original.mov', 'original.mov')
    assert (metadata.displayWidth, metadata.displayHeight) == dimensions
    assert metadata.codec == 'hevc'
    assert metadata.videoStreamIndex == 2 and metadata.audioStreamIndex == 3
    assert metadata.videoStartSec == .2
    assert metadata.avgFrameRate == pytest.approx(29.97003)
    arguments = proxy_args(Path('source.mov'), Path('proxy.mp4'), metadata)
    assert '0:2' in arguments and '0:3' in arguments
    assert '-copyts' in arguments
    assert max(proxy_dimensions(metadata)) <= 1920
    assert 'setpts=PTS-(0.200000000)/TB' in arguments[arguments.index('-vf') + 1]
    assert 'asetpts=PTS-(0.200000000)/TB' in arguments[arguments.index('-af') + 1]


def test_invalid_probe() -> None:
    with pytest.raises(MediaError):
        parse_probe({'streams': []}, 'source/a.mp4', 'a.mp4')
    with pytest.raises(MediaError, match='non-right-angle'):
        parse_probe(probe_document(33), 'source/a.mp4', 'a.mp4')


def wait_job(manager: JobManager, job_id: str) -> str:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        status = manager.get(job_id).status
        if status in ('completed', 'failed', 'cancelled'):
            return status
        time.sleep(.01)
    raise AssertionError('Job timed out')


def test_job_completion_failure_cancel_and_recovery(tmp_path: Path) -> None:
    store = ProjectStore(tmp_path)
    project = stored_project(store)
    captured: list[str] = []

    def renderer(snapshot, _folder, output, _temp, progress, event):
        captured.append(snapshot.projectName)
        progress(10)
        output.write_bytes(b'export')

    manager = JobManager(store, renderer=renderer, validator=lambda _path, _project: None)
    job = manager.create(project)
    project.projectName = 'mutated after export'
    assert wait_job(manager, job.jobId) == 'completed'
    assert captured == ['Test']
    assert manager.get(job.jobId).progress == 100
    manager.close()
    recovered = JobManager(store)
    assert recovered.get(job.jobId).status == 'completed'
    assert recovered.output_path(job).is_file()
    recovered.close()

    def fail(*_args):
        raise RuntimeError('internal details')

    manager = JobManager(store, renderer=fail)
    job = manager.create(project)
    assert wait_job(manager, job.jobId) == 'failed'
    assert 'internal details' not in manager.get(job.jobId).error
    manager.close()

    entered = threading.Event()

    def cancel(_project, _folder, _output, _temp, _progress, event):
        entered.set()
        assert event.wait(3)
        raise ExportCancelled()

    manager = JobManager(store, renderer=cancel)
    job = manager.create(project)
    assert entered.wait(3)
    queued = manager.create(project)
    assert manager.cancel(queued.jobId).status == 'cancelled'
    manager.cancel(job.jobId)
    assert wait_job(manager, job.jobId) == 'cancelled'
    manager.close()
    assert not list((store.project_dir(project.projectId) / 'temp').iterdir())
    job.status = 'running'
    atomic_json(store.project_dir(project.projectId) / 'exports' / f'{job.jobId}.json', job.model_dump())
    manager = JobManager(store)
    assert manager.get(job.jobId).status == 'failed'
    assert 'restart' in manager.get(job.jobId).error
    manager.close()


def test_api_validation_range_and_origin_security(tmp_path: Path) -> None:
    application = create_app(Config(data_dir=tmp_path, max_upload_bytes=32))
    project = stored_project(application.state.store)
    with TestClient(application, base_url='http://localhost:8000') as client:
        assert client.get('/api/health').json()['ffmpeg']
        assert client.get('/api/projects').json()[0]['projectId'] == project.projectId
        response = client.get(f'/api/projects/{project.projectId}/video', headers={'Range': 'bytes=0-2'})
        assert response.status_code == 206 and response.content == b'pro'
        assert response.headers['content-range'] == 'bytes 0-2/5'
        response = client.put(f'/api/projects/{project.projectId}', json=project.model_dump(),
                              headers={'Origin': 'https://evil.example'})
        assert response.status_code == 403
        assert client.get('/api/projects', headers={'Host': 'evil.example'}).status_code == 400
        assert client.get('/api/projects', headers={'Host': '[malformed'}).status_code == 400
        assert client.put(f'/api/projects/{project.projectId}', json=project.model_dump(),
                          headers={'Host': 'localhost:8001', 'Origin': 'http://localhost:8001', 'If-Match': f'"{project.revision}"'}).status_code == 200
        document = project.model_dump()
        document['annotations'][0]['endSec'] = 21
        assert client.put(f'/api/projects/{project.projectId}', json=document).status_code == 422
        assert client.post('/api/projects/import', files={'file': ('bad.mp4', b'0' * 40, 'video/mp4')}).status_code == 413
        assert client.post('/api/projects/import', files={'file': ('bad.txt', b'bad', 'text/plain')}).status_code == 415
        assert client.post('/api/projects/import', files={'file': ('bad.mp4', b'bad', 'video/mp4')}).status_code == 422
        assert len(application.state.store.list()) == 1  # partial imports removed
        assert client.delete(f'/api/projects/{project.projectId}', headers={'If-Match': f'"{project.revision + 1}"'}).status_code == 204
        assert client.get(f'/api/projects/{project.projectId}').status_code == 404


def test_real_import_preserves_source_and_delayed_audio(tmp_path: Path) -> None:
    source = tmp_path / 'delayed.mov'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=blue:s=160x120:r=30:d=2',
                    '-itsoffset', '0.25', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=1.75',
                    '-c:v', 'mpeg4', '-c:a', 'aac', '-threads', '2', str(source)], check=True)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    application = create_app(Config(data_dir=tmp_path / 'data'))
    with TestClient(application, base_url='http://localhost:8000') as client:
        with source.open('rb') as handle:
            response = client.post('/api/projects/import', files={'file': ('delayed.mov', handle, 'video/quicktime')})
        assert response.status_code == 200, response.text
        project = Project.model_validate(response.json())
        assert project.source.codec == 'mpeg4' and project.proxy.codec == 'h264'
        assert project.proxy.hasAudio and project.proxy.rotation == 0
        folder = application.state.store.project_dir(project.projectId)
        assert hashlib.sha256((folder / project.source.asset).read_bytes()).hexdigest() == digest
        proxy = folder / project.proxy.asset
        assert probe_media(proxy, project.proxy.asset, 'proxy.mp4').durationSec == pytest.approx(2, abs=1/30)
        audio = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(proxy), '-vn', '-ac', '1', '-ar', '48000',
                                '-f', 'f32le', 'pipe:1'], check=True, capture_output=True).stdout
        values = array.array('f', audio)
        def rms(start: float, end: float) -> float:
            return math.sqrt(sum(v*v for v in values[int(start*48000):int(end*48000)]) / int((end-start)*48000))
        assert rms(.02, .15) < .001
        assert rms(.35, .5) > .05
        # Reload through a fresh backend instance, not only the browser state.
        assert ProjectStore(tmp_path / 'data').load(project.projectId).source.codec == 'mpeg4'
        assert client.get(f'/api/projects/{project.projectId}/video', headers={'Range': 'bytes=0-31'}).status_code == 206


@pytest.mark.parametrize('contents', [
    '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nhttp://127.0.0.1:1/private.mp4\n#EXT-X-ENDLIST\n',
    "ffconcat version 1.0\nfile '/etc/passwd'\n",
])
def test_uploaded_playlists_cannot_reference_other_assets(tmp_path: Path, contents: str) -> None:
    path = tmp_path / 'disguised.mp4'
    path.write_text(contents, encoding='utf-8')
    with pytest.raises(MediaError, match='cannot be read'):
        probe_media(path, 'source/disguised.mp4', 'disguised.mp4')
