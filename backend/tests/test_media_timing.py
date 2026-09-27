"""Independent PTS and moving-pixel checks; proxy stepping is not source stepping."""
import base64
import json
import subprocess
import threading
from pathlib import Path

import pytest

from app.assets import digest_file
from app.media import create_proxy, probe_media
from app.renderer import render_export
from test_renderer import annotation, make_project, sample_frame

CASES = json.loads((Path(__file__).resolve().parents[2] / 'tests/fixtures/media-timing-conformance.json').read_text())['cases']


@pytest.mark.integration
@pytest.mark.parametrize('case', CASES, ids=lambda case: case['name'])
def test_pts_survive_proxy_and_final_time_mapping(tmp_path, case):
    source = tmp_path / 'source/original.mp4'
    source.parent.mkdir()
    source.write_bytes(base64.b64decode(case['movieBase64']))
    assert digest_file(source) == case['sha256']
    timestamps = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_frames', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(source)], check=True, capture_output=True, text=True).stdout)['frames']
    actual = [float(frame['best_effort_timestamp_time']) for frame in timestamps]
    expected = [tick / case['timescale'] for tick in case['ptsTicks']]
    assert actual == pytest.approx(expected, abs=1e-6)
    if case['name'] == 'variable-frame-rate':
        assert {round((b - a) * case['timescale']) for a, b in zip(actual, actual[1:], strict=False)} == {1, 2, 4}
    cue = annotation('rectangle', start=.5, end=1.5, geometry={'x': .1, 'y': .1, 'width': .4, 'height': .4}, fillOpacity=1)
    project = make_project(source, [cue])
    preview = tmp_path / 'preview.mp4'
    create_proxy(source, preview, project.source)
    output = tmp_path / 'exports/review.mp4'
    render_export(project, tmp_path, output, tmp_path / 'temp', lambda _: None, threading.Event())
    for movie in [preview, output]:
        metadata = probe_media(movie, 'proxy/result.mp4', 'result.mp4')
        assert metadata.avgFrameRate == 30
        assert metadata.durationSec == pytest.approx(2, abs=.1)
        assert (metadata.displayWidth, metadata.displayHeight) == (320, 180)
        for frame, green in [(29, False), (30, True), (31, True)]:
            pixel = sample_frame(movie, frame, 320, 180).getpixel((280, 140))
            assert pixel[1 if green else 2] > 200 and pixel[2 if green else 1] < 40
    for frame, red in [(14, False), (15, True), (44, True), (45, False)]:
        pixel = sample_frame(output, frame, 320, 180).getpixel((60, 40))
        assert (pixel[0] > 200 and pixel[1] < 40 and pixel[2] < 40) is red
    assert digest_file(source) == case['sha256']
