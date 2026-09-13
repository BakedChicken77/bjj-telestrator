"""Actual recording normalization, immediate preview, asset binding, and deletion safety."""
from __future__ import annotations

import io
import subprocess
import threading
import wave
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.config import Config
from app.main import create_app
from app.models import Project
from app.renderer import ExportCancelled
from app.storage import ProjectStore


def ffmpeg(*args: str) -> None:
    subprocess.run(['ffmpeg', '-v', 'error', '-y', *args], check=True, capture_output=True)


@pytest.fixture
def recording(tmp_path: Path) -> Path:
    path = tmp_path / 'recording.webm'
    ffmpeg('-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=44100:duration=1',
           '-ac', '2', '-c:a', 'libopus', str(path))
    return path


@pytest.fixture
def client_project(tmp_path: Path):
    source = tmp_path / 'silent.mp4'
    ffmpeg('-f', 'lavfi', '-i', 'color=c=blue:s=160x120:r=30:d=2',
           '-an', '-c:v', 'libx264', '-threads', '2', '-pix_fmt', 'yuv420p', str(source))
    application = create_app(Config(data_dir=tmp_path / 'data'))
    with TestClient(application, base_url='http://localhost:8000') as client:
        with source.open('rb') as handle:
            response = client.post('/api/projects/import', files={'file': ('silent.mp4', handle, 'video/mp4')})
        assert response.status_code == 200, response.text
        yield client, application, response.json()


def upload(client: TestClient, project: dict, recording: Path, start: str = '0.5') -> dict:
    with recording.open('rb') as handle:
        response = client.post(f"/api/projects/{project['projectId']}/voiceovers", data={'startSec': start},
                               files={'file': ('recording.webm', handle, 'audio/webm;codecs=opus')})
    assert response.status_code == 200, response.text
    return response.json()


def save_project(client, project):
    response = client.put(f"/api/projects/{project['projectId']}", json=project,
                          headers={'If-Match': f'"{project["revision"]}"'})
    if response.status_code == 200:
        project['revision'] = response.json()['revision']
    return response


def test_real_recording_normalization_immediate_preview_clamp_and_restart(client_project, recording: Path) -> None:
    client, application, project = client_project
    assert not project['source']['hasAudio']
    clip = upload(client, project, recording, '1.5')
    assert clip['codec'] == 'pcm_s16le' and clip['sampleRate'] == 48000 and clip['channels'] == 1
    assert clip['durationSec'] == pytest.approx(.5, abs=1/48000)
    assert clip['endSec'] <= project['source']['durationSec']
    response = client.get(f"/api/projects/{project['projectId']}/voiceovers/{clip['id']}/audio")
    assert response.status_code == 200 and response.headers['content-type'] == 'audio/wav'
    with wave.open(io.BytesIO(response.content), 'rb') as audio:
        assert audio.getframerate() == 48000 and audio.getnchannels() == 1
        assert audio.getnframes() == 24000
        assert any(audio.readframes(24000))
    assert client.get(f"/api/projects/{project['projectId']}").json()['voiceovers'] == []
    project['voiceovers'] = [clip]
    saved = save_project(client, project)
    assert saved.status_code == 200, saved.text
    store = ProjectStore(application.state.config.data_dir)
    assert store.load(project['projectId']).voiceovers[0].id == clip['id']
    assert store.voiceover_metadata(project['projectId'], clip['id']).durationSec == .5
    folder = store.project_dir(project['projectId'])
    assert not list((folder / 'temp').iterdir())
    assert len(list((folder / 'voiceover').iterdir())) == 2  # WAV plus server metadata


def test_soft_remove_restores_for_undo_and_project_delete_removes_assets(client_project, recording: Path) -> None:
    client, application, project = client_project
    clip = upload(client, project, recording)
    project['voiceovers'] = [clip]
    assert save_project(client, project).status_code == 200
    project['voiceovers'] = []
    assert save_project(client, project).status_code == 200
    assert client.get(f"/api/projects/{project['projectId']}/voiceovers/{clip['id']}/audio").status_code == 200
    project['voiceovers'] = [clip]
    assert save_project(client, project).status_code == 200
    directory = application.state.store.project_dir(project['projectId'])
    assert client.delete(f"/api/projects/{project['projectId']}", headers={'If-Match': f'"{project["revision"]}"'}).status_code == 204
    assert not directory.exists()


@pytest.mark.parametrize('field,value', [('asset', 'source/original.mp4'), ('id', str(uuid4())),
                                       ('durationSec', .25), ('codec', 'aac'), ('sampleRate', 44100),
                                       ('channels', 2), ('recordedAt', '2026-09-01T00:00:00Z')])
def test_voiceover_identity_is_bound_to_registered_asset(client_project, recording: Path, field: str, value: object) -> None:
    client, _, project = client_project
    clip = upload(client, project, recording)
    clip[field] = value
    if field == 'durationSec':
        clip['endSec'] = clip['startSec'] + clip['durationSec']
    project['voiceovers'] = [clip]
    response = save_project(client, project)
    assert response.status_code == 400, response.text
    assert 'registered' in response.text or 'cannot be changed' in response.text


def test_timing_nudge_gain_mute_validation_and_unknown_fields(client_project, recording: Path) -> None:
    client, _, project = client_project
    clip = upload(client, project, recording)
    clip.update({'startSec': .4, 'endSec': .4 + clip['durationSec'], 'timingOffsetMs': 200,
                 'gain': .6, 'muted': True, 'futureClipField': 'retain'})
    project['voiceovers'] = [clip]
    project['settings'].update({'originalAudioGain': .2, 'originalAudioMuted': True, 'voiceoverMasterGain': 1.5})
    saved = save_project(client, project)
    assert saved.status_code == 200, saved.text
    assert saved.json()['voiceovers'][0]['futureClipField'] == 'retain'
    clip['timingOffsetMs'] = -500
    assert save_project(client, project).status_code == 422
    clip['timingOffsetMs'] = 1000
    assert save_project(client, project).status_code == 422
    clip['timingOffsetMs'] = 0
    clip['endSec'] += .1
    with pytest.raises(ValidationError):
        Project.model_validate(project)


def test_permanent_delete_protects_active_snapshot_and_rejects_stale_reference(client_project, recording: Path) -> None:
    client, application, project = client_project
    clip = upload(client, project, recording)
    project['voiceovers'] = [clip]
    assert save_project(client, project).status_code == 200
    entered = threading.Event()

    def hold(_project, _folder, _output, _temp, _progress, cancelled):
        entered.set()
        assert cancelled.wait(3)
        raise ExportCancelled()

    application.state.jobs.renderer = hold
    job = client.post(f"/api/projects/{project['projectId']}/exports", headers={"If-Match": f'"{project["revision"]}"'}).json()
    assert entered.wait(3)
    endpoint = f"/api/projects/{project['projectId']}/voiceovers/{clip['id']}"
    assert client.delete(endpoint).status_code == 409
    client.post(f"/api/exports/{job['jobId']}/cancel")
    application.state.jobs.close()
    # Terminal snapshots and undo still own the immutable recording after cancel.
    assert client.delete(endpoint).status_code == 409
    assert client.get(endpoint + '/audio').status_code == 200
    assert client.get(f"/api/projects/{project['projectId']}").json()['voiceovers'][0]['id'] == clip['id']
    project['voiceovers'] = []
    assert save_project(client, project).status_code == 200
    project['voiceovers'] = [clip]
    assert save_project(client, project).status_code == 200



@pytest.mark.parametrize('contents,mime,start,status', [
    (b'', 'audio/webm', '0', 422), (b'broken recording', 'audio/webm', '0', 422),
    (b'plain text', 'text/plain', '0', 415), (b'fake', 'audio/webm', '2', 422),
    (b'fake', 'audio/webm', '-1', 422), (b'fake', 'audio/webm', 'NaN', 422),
    (b"ffconcat version 1.0\nfile '/etc/passwd'\n", 'audio/webm', '0', 422),
])
def test_invalid_recordings_cleanup(client_project, contents: bytes, mime: str, start: str, status: int) -> None:
    client, application, project = client_project
    response = client.post(f"/api/projects/{project['projectId']}/voiceovers", data={'startSec': start},
                           files={'file': ('recording.webm', contents, mime)})
    assert response.status_code == status, response.text
    folder = application.state.store.project_dir(project['projectId'])
    assert not list((folder / 'temp').iterdir())
    assert not list((folder / 'voiceover').iterdir())


def test_video_without_audio_rejected_as_recording(client_project, tmp_path: Path) -> None:
    client, application, project = client_project
    source = application.state.store.project_dir(project['projectId']) / project['source']['asset']
    with source.open('rb') as handle:
        response = client.post(f"/api/projects/{project['projectId']}/voiceovers", data={'startSec': '0'},
                               files={'file': ('recording.mp4', handle, 'audio/mp4')})
    assert response.status_code == 422 and 'no audio stream' in response.text
