"""Small synthetic PTS fixtures shared by native and FFmpeg tests."""
from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


def main():
    cases = []
    with tempfile.TemporaryDirectory(prefix='bjj-timing-') as temporary:
        for name in ['120fps-original', 'variable-frame-rate']:
            path = Path(temporary) / f'{name}.mp4'
            frames = list(range(240)) if name == '120fps-original' else [n for n in range(240) if (n < 120 and n % 4 == 0) or (n >= 120 and n % 2 == 0) or n == 239]
            selection = '' if name == '120fps-original' else ",select='if(lt(n,120),not(mod(n,4)),not(mod(n,2)))+eq(n,239)'"
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=320x180:r=120:d=2',
                            '-vf', "drawbox=x=0:y=0:w=iw:h=ih:color=lime:t=fill:enable='gte(t,1)'" + selection,
                            '-fps_mode', 'vfr', '-c:v', 'libx264', '-threads', '2', '-pix_fmt', 'yuv420p', '-video_track_timescale', '12000', str(path)], check=True)
            raw = path.read_bytes()
            cases.append({'name': name, 'movieBase64': base64.b64encode(raw).decode(),
                          'sha256': hashlib.sha256(raw).hexdigest(), 'durationSec': 2,
                          'ptsTicks': frames, 'timescale': 120, 'colorChangeSec': 1})
    target = Path(__file__).resolve().parents[1] / 'tests/fixtures/media-timing-conformance.json'
    target.write_text(json.dumps({'version': 1, 'cases': cases}, indent=2) + '\n')
    print(f'{len(cases)} timing fixtures, {target.stat().st_size} bytes')


if __name__ == '__main__':
    main()
