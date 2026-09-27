"""Verify processing and internal TestFlight access; safe to retry without re-uploading.

Uses Apple's documented App Store Connect API and the existing ios-release key.
Never creates testers, sends invitations, or submits a public App Store release.
"""

import argparse
import base64
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
API = 'https://api.appstoreconnect.apple.com'
APP = '6816524004'
GROUP = '155e7ca8-b2a1-45b0-98ce-c25399335496'
BUNDLE = 'com.bakedchicken77.bjjtelestrator'


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


def raw_signature(der: bytes) -> bytes:
    # OpenSSL emits a DER ECDSA sequence; JWT ES256 uses fixed-width r || s.
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError('Invalid ES256 signature sequence')
    offset, parts = 2, []
    for _ in range(2):
        if offset + 2 > len(der) or der[offset] != 2:
            raise ValueError('Invalid ES256 signature integer')
        length = der[offset + 1]
        value = der[offset + 2:offset + 2 + length]
        if len(value) != length or not value or value[0] & 0x80:
            raise ValueError('Invalid ES256 signature integer')
        value = value.lstrip(b'\0')
        if len(value) > 32:
            raise ValueError('ES256 integer exceeds 256 bits')
        parts.append(value.rjust(32, b'\0'))
        offset += 2 + length
    if offset != len(der):
        raise ValueError('Unexpected ES256 signature data')
    return b''.join(parts)


class AppleAPI:
    def __init__(self, key: Path, key_id: str, issuer: str):
        self.key, self.key_id, self.issuer = key, key_id, issuer

    def token(self) -> str:
        now = int(time.time())
        header = b64(json.dumps({'alg': 'ES256', 'kid': self.key_id, 'typ': 'JWT'}).encode())
        body = b64(json.dumps({'iss': self.issuer, 'iat': now - 15, 'exp': now + 300,
                               'aud': 'appstoreconnect-v1'}).encode())
        message = f'{header}.{body}'
        result = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(self.key)],
                                input=message.encode(), capture_output=True)
        if result.returncode:
            raise RuntimeError('Could not sign App Store Connect API token')
        return f'{message}.{b64(raw_signature(result.stdout))}'

    def request(self, path: str, method: str = 'GET', data=None):
        url = path if path.startswith('https://') else API + path
        if urlsplit(url).netloc != urlsplit(API).netloc or urlsplit(url).scheme != 'https':
            raise ValueError('Refusing to send Apple credentials to another origin')
        for attempt in range(4):
            req = Request(url, data=json.dumps(data).encode() if data is not None else None,
                          headers={'Authorization': 'Bearer ' + self.token(),
                                   'Content-Type': 'application/json'}, method=method)
            try:
                with urlopen(req, timeout=60) as response:
                    body = response.read()
                    return json.loads(body) if body else {}
            except HTTPError as error:
                if error.code in {429, 500, 502, 503, 504} and attempt < 3:
                    time.sleep(15)
                    continue
                # Do not echo HTTP bodies or request headers that may contain private data.
                raise RuntimeError(f'Apple API {method} failed with HTTP {error.code}') from None
        raise RuntimeError('Apple API retry limit reached')

    def items(self, path: str):
        while path:
            response = self.request(path)
            yield from response['data']
            path = response.get('links', {}).get('next')


def distribute(api, version: str, build: str, receipt: dict, timeout=1800, interval=30,
               clock=time.monotonic, sleep=time.sleep):
    app = api.request(f'/v1/apps/{APP}')['data']
    if app['attributes']['bundleId'] != BUNDLE:
        raise ValueError('App identity does not match the signed application')
    group = api.request(f'/v1/betaGroups/{GROUP}')['data']
    group_app = api.request(f'/v1/betaGroups/{GROUP}/app')['data']
    if group_app['id'] != APP or not group['attributes']['isInternalGroup']:
        raise ValueError('The configured testing group must be internal and belong to this app')
    testers = list(api.items(f'/v1/betaGroups/{GROUP}/betaTesters?limit=200'))
    if not any(t['attributes'].get('email', '').lower() == 'steven.long.engine@gmail.com' for t in testers):
        raise ValueError('The owner tester is not in the configured testing group')
    receipt.update(appId=APP, groupId=GROUP, version=version, build=build,
                   hasAccessToAllBuilds=group['attributes'].get('hasAccessToAllBuilds'),
                   ownerTesterAssigned=True, available=False)
    query = urlencode({'filter[app]': APP, 'filter[version]': build,
                       'filter[preReleaseVersion.version]': version, 'limit': 10})
    deadline = clock() + timeout
    assigned = False
    while clock() < deadline:
        matches = list(api.items('/v1/builds?' + query))
        if len(matches) > 1:
            raise ValueError('Ambiguous build identity; refusing to distribute')
        if matches:
            item = matches[0]
            attributes = item['attributes']
            state = attributes['processingState']
            receipt.update(buildId=item['id'], processingState=state)
            if attributes.get('expired') or state in {'FAILED', 'INVALID'}:
                raise RuntimeError(f'Apple build is expired or processing failed: {state}')
            if state == 'VALID':
                groups = list(api.items(f'/v1/betaGroups/{GROUP}/relationships/builds?limit=200'))
                member = any(g['id'] == item['id'] for g in groups)
                if not member and not assigned:
                    api.request(f'/v1/betaGroups/{GROUP}/relationships/builds', 'POST',
                                {'data': [{'type': 'builds', 'id': item['id']}]})
                    assigned = True
                    groups = list(api.items(f'/v1/betaGroups/{GROUP}/relationships/builds?limit=200'))
                    member = any(g['id'] == item['id'] for g in groups)
                detail = api.request(f"/v1/builds/{item['id']}/buildBetaDetail")['data']['attributes']
                receipt.update(groupAssigned=member, internalBuildState=detail.get('internalBuildState'))
                if member and detail.get('internalBuildState') == 'IN_BETA_TESTING':
                    receipt['available'] = True
                    print(f'TestFlight {version} ({build}) is available to the existing internal group.', flush=True)
                    return
        print(f"Waiting for TestFlight {version} ({build}): {receipt.get('processingState', 'not listed')}", flush=True)
        sleep(interval)
    raise TimeoutError('Apple has not confirmed tester access yet. Retry distribution only; do not upload this build again.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    receipt = {'sourceSha': os.environ.get('GITHUB_SHA', '')}
    output = ROOT / '.ci-artifacts/testflight-distribution.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='bjj-distribution-', dir=os.environ.get('RUNNER_TEMP')) as folder:
            key = Path(folder) / 'key.p8'
            key.write_bytes(base64.b64decode(os.environ['ASC_API_KEY_P8_BASE64'], validate=True))
            key.chmod(0o600)
            distribute(AppleAPI(key, os.environ['ASC_API_KEY_ID'], os.environ['ASC_API_ISSUER_ID']),
                       args.version, args.build, receipt)
    finally:
        output.write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
