"""Repackage the licensed Dolby source as an independently decodable hvc1 excerpt.

Usage: python scripts/generate_dolby_fixture.py /path/to/upstream.mp4
No video re-encoding, download or user media is involved. See DOLBY_LICENSE.md.
"""
import argparse
import base64
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_SHA = 'd81d4c17958946796f30ca28a57776cee187a421649058767c8496cbc1e469bf'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    if hashlib.sha256(args.source.read_bytes()).hexdigest() != UPSTREAM_SHA:
        raise SystemExit('Not the licensed, pinned Dolby source; refusing fixture generation.')
    with tempfile.TemporaryDirectory(prefix='dolby-fixture-') as folder:
        remux = Path(folder) / 'remux.mp4'
        excerpt = Path(folder) / 'excerpt.mp4'
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(args.source), '-map', '0:v:0',
                        '-c', 'copy', '-bsf:v', 'hevc_mp4toannexb,extract_extradata',
                        '-strict', 'unofficial', str(remux)], check=True)
        subprocess.run(['ffmpeg', '-v', 'error', '-ss', '20', '-i', str(remux), '-t', '2',
                        '-map', '0:v:0', '-c', 'copy', '-tag:v', 'hvc1', '-strict', 'unofficial',
                        '-movflags', '+faststart', str(excerpt)], check=True)
        data = excerpt.read_bytes()
    path = ROOT / 'tests/fixtures/dolby84-conformance.json'
    fixture = json.loads(path.read_text())
    fixture['attribution'] = ('Sol Levante by Netflix, Inc.; Dolby, Inc. Dolby Vision adaptation. '
                              'CC BY 4.0. Fresh Frame two-second excerpt near 20s; stream copy '
                              'with parameter-set extraction and hvc1 packaging, no re-encoding.')
    fixture['sha256'] = hashlib.sha256(data).hexdigest()
    fixture['movieBase64'] = base64.b64encode(data).decode()
    path.write_text(json.dumps(fixture, indent=2) + '\n')
    print(fixture['sha256'])


if __name__ == '__main__':
    main()
