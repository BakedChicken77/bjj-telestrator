"""Reproduce tiny, synthetic 10-bit PQ/HLG movies shared by Python and XCTest.

The frames are controlled neutral ramps (not ordinary SDR with HDR tags).
Only encoded test media, hashes and independently chosen patch locations are
checked in; no coaching footage or decoded intermediates are retained.
"""
from __future__ import annotations

import base64
import hashlib
import json
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def generate(destination: Path) -> None:
    cases = []
    width, height = 320, 180
    for transfer, levels in [('smpte2084', [0, .1, .25, .4, .5, .6, .68, .75]),
                             ('arib-std-b67', [0, .1, .25, .4, .5, .65, .8, .95])]:
        row = [round(64 + 876 * levels[x // 40]) for x in range(width)]
        samples = row * height + [512] * (width * height // 2)
        frame = struct.pack('<' + 'H' * len(samples), *samples)
        with tempfile.TemporaryDirectory() as directory:
            movie = Path(directory) / 'ramp.mp4'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'yuv420p10le',
                            '-s', f'{width}x{height}', '-r', '30', '-i', 'pipe:0', '-frames:v', '60',
                            '-an', '-c:v', 'libx265', '-preset', 'fast', '-x265-params',
                            'pools=1:frame-threads=1:log-level=error:lossless=1:repeat-headers=1',
                            '-tag:v', 'hvc1', '-color_primaries', 'bt2020', '-color_trc', transfer,
                            '-colorspace', 'bt2020nc', '-color_range', 'tv', str(movie)],
                           input=frame * 60, check=True)
            data = movie.read_bytes()
        cases.append({'name': transfer, 'transferFunction': transfer, 'byteSize': len(data),
                      'sha256': hashlib.sha256(data).hexdigest(), 'movieBase64': base64.b64encode(data).decode(),
                      'inputCodeFractions': levels, 'sampleX': [20 + i * 40 for i in range(8)],
                      'sampleY': 135, 'width': width, 'height': height, 'durationSec': 2})
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps({'version': 1, 'cases': cases}, indent=2) + '\n')


if __name__ == '__main__':
    generate(ROOT / 'tests/fixtures/hdr-conformance.json')
