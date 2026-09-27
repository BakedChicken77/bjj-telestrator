"""Distribution safety: exact build, existing group, read-back, no duplicate uploads."""

import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.ci.distribute_testflight import APP, BUNDLE, GROUP, distribute, raw_signature


class FakeApple:
    def __init__(self, state='VALID', internal=True, assigned=False, beta='IN_BETA_TESTING'):
        self.state, self.internal, self.assigned, self.beta = state, internal, assigned, beta
        self.posts = []
        self.ignore_assignment = False

    def request(self, path, method='GET', data=None):
        if method == 'POST':
            self.posts.append((path, data))
            if not self.ignore_assignment:
                self.assigned = True
            return {}
        if path == f'/v1/apps/{APP}':
            return {'data': {'attributes': {'bundleId': BUNDLE}}}
        if path == f'/v1/betaGroups/{GROUP}':
            return {'data': {'attributes': {'isInternalGroup': self.internal, 'hasAccessToAllBuilds': False}}}
        if path == f'/v1/betaGroups/{GROUP}/app':
            return {'data': {'id': APP}}
        if path == '/v1/builds/exact-build/buildBetaDetail':
            return {'data': {'attributes': {'internalBuildState': self.beta}}}
        raise AssertionError(path)

    def items(self, path):
        if '/betaTesters?' in path:
            return [{'attributes': {'email': 'steven.long.engine@gmail.com'}}]
        if path.startswith('/v1/builds?'):
            assert '2.0.0' in path and '7.1' in path and APP in path
            return [{'id': 'exact-build', 'attributes': {'processingState': self.state, 'expired': False}}]
        if '/relationships/builds?' in path:
            return [{'id': 'exact-build'}] if self.assigned else []
        raise AssertionError(path)


class DistributionTests(unittest.TestCase):
    def run_distribution(self, api):
        ticks = iter([0, 0, 2])
        receipt = {}
        distribute(api, '2.0.0', '7.1', receipt, timeout=1, interval=0,
                   clock=lambda: next(ticks), sleep=lambda _: None)
        return receipt

    def test_assignment_is_read_back_and_retry_is_idempotent(self):
        api = FakeApple()
        self.assertTrue(self.run_distribution(api)['available'])
        self.assertEqual(api.posts, [(f'/v1/betaGroups/{GROUP}/relationships/builds',
                                     {'data': [{'type': 'builds', 'id': 'exact-build'}]})])
        self.assertTrue(self.run_distribution(api)['available'])
        self.assertEqual(len(api.posts), 1)

    def test_processing_failure_external_group_and_unconfirmed_access_fail_closed(self):
        for api, error in [(FakeApple(state='INVALID'), RuntimeError),
                           (FakeApple(internal=False), ValueError),
                           (FakeApple(state='PROCESSING'), TimeoutError),
                           (FakeApple(beta='MISSING_EXPORT_COMPLIANCE'), TimeoutError)]:
            with self.subTest(api=api), self.assertRaises(error):
                self.run_distribution(api)
        api = FakeApple()
        api.ignore_assignment = True
        with self.assertRaises(TimeoutError):
            self.run_distribution(api)

    def test_openssl_signature_conversion_preserves_r_and_s(self):
        with tempfile.TemporaryDirectory() as folder:
            key = Path(folder) / 'test.pem'
            subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(key)], check=True)
            for _ in range(8):
                signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key)],
                                           input=b'fixture', capture_output=True, check=True).stdout
                raw = raw_signature(signature)
                self.assertEqual(len(raw), 64)
                n = signature[3]
                self.assertEqual(int.from_bytes(raw[:32]), int.from_bytes(signature[4:4+n]))
                self.assertEqual(int.from_bytes(raw[32:]), int.from_bytes(signature[6+n:]))
        for value in [b'', b'not DER', b'\x30\x06\x02\x01\x80\x02\x01\x01']:
            with self.assertRaises(ValueError):
                raw_signature(value)
