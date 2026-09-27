"""Actual HDR decode, SDR preview/export pixels, capability and source checks."""
import base64
import json
import subprocess
import threading
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.assets import digest_file
from app.color import require_supported_color
from app.config import Config
from app.errors import DomainError
from app.main import create_app
from app.media import probe_media
from app.models import Project
from app.renderer import render_export
from test_backend import raw_project

CASES = json.loads((Path(__file__).parents[2] / 'tests/fixtures/hdr-conformance.json').read_text())['cases']


def frame(path, time):
    return subprocess.run(['ffmpeg', '-v', 'error', '-ss', str(time), '-i', str(path),
                           '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'],
                          capture_output=True, check=True).stdout


@pytest.mark.integration
@pytest.mark.parametrize('case', CASES, ids=lambda case: case['name'])
def test_real_hdr_preview_and_export_preserve_ramp_cues_and_source(tmp_path, case):
    original = tmp_path / 'ramp.mp4'
    original.write_bytes(base64.b64decode(case['movieBase64'], validate=True))
    assert original.stat().st_size == case['byteSize'] and digest_file(original) == case['sha256']
    inspected = probe_media(original, 'source/ramp.mp4', 'ramp.mp4')
    assert inspected.codec == 'hevc' and inspected.transferFunction == case['transferFunction']
    app = create_app(Config(data_dir=tmp_path / 'data'))
    with TestClient(app, base_url='http://localhost:8000') as client:
        with original.open('rb') as handle:
            result = client.post('/api/projects/import', files={'file': ('ramp.mp4', handle, 'video/mp4')})
        assert result.status_code == 200, result.text
        document = result.json()
        assert 'media.hdr-to-sdr.v1' in document['requiredCapabilities']
        cue = raw_project()['annotations'][0]
        cue.update(type='rectangle', startSec=.5, endSec=1.5, strokeColor='#ff0000',
                   fillColor='#ff0000', fillOpacity=1,
                   geometry={'x': .1, 'y': .1, 'width': .4, 'height': .4})
        document['annotations'] = [cue]
        store = app.state.store
        project = store.save(Project.model_validate(document))
        folder = store.project_dir(project.projectId)
        output = tmp_path / 'review.mp4'
        render_export(project, folder, output, tmp_path / 'render', lambda _seconds: None, threading.Event())
        preview = folder / project.proxy.asset
        ramps = []
        for path in (preview, output):
            metadata = probe_media(path, 'proxy/test.mp4', 'test.mp4')
            assert metadata.codec == 'h264' and not metadata.hasAudio
            assert (metadata.colorPrimaries, metadata.transferFunction, metadata.colorMatrix, metadata.colorRange) == ('bt709', 'bt709', 'bt709', 'tv')
            assert metadata.durationSec == pytest.approx(2, abs=1/30)
            pixels = frame(path, .25)
            ramp = [pixels[(case['sampleY'] * 320 + x) * 3] for x in case['sampleX']]
            assert ramp[0] < 12 and ramp[-1] > 210, ramp
            assert all(b > a + 1 for a, b in zip(ramp, ramp[1:], strict=False)), ramp
            ramps.append(ramp)
        assert max(abs(a - b) for a, b in zip(*ramps, strict=True)) <= 6, ramps
        for time, present in [(.25, False), (.5, True), (1.25, True), (1.5, False)]:
            pixels = frame(output, time)
            r, g, b = pixels[(45 * 320 + 70) * 3: (45 * 320 + 70) * 3 + 3]
            assert (r > 210 and g < 40 and b < 40) == present, (time, r, g, b)
        assert digest_file(folder / project.source.asset) == case['sha256']
        assert store.load(project.projectId).source.transferFunction == case['transferFunction']
        print(f"HDR {case['name']}: preview/export ramps={ramps} h264/709 320x180 2s bytes={output.stat().st_size} source_sha256={case['sha256']}")


@pytest.mark.parametrize('change', [{'colorPrimaries': 'unknown'}, {'colorMatrix': 'unknown'},
                                    {'colorRange': 'unknown'}, {'dolbyVision': True}])
def test_hdr_rejects_unknown_color_or_unverified_dolby_vision(change):
    media = {'transferFunction': 'smpte2084', 'colorPrimaries': 'bt2020', 'colorMatrix': 'bt2020nc', 'colorRange': 'tv', **change}
    with pytest.raises(DomainError, match='HDR|Dolby Vision') as error:
        require_supported_color(media)
    assert error.value.code == 'MEDIA_UNSUPPORTED'
