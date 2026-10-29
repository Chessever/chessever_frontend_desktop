"""Readiness must be positive; attestation must describe this exact candidate."""
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from mac_app_store_release_gates import (ENDPOINTS, SMOKE_CHECKS, OPERATIONAL_CHECKS, endpoint_readiness,
                                         review_evidence, source_fingerprint)


class HealthResponse(io.BytesIO):
    status = 200


class HealthOpener:
    def __init__(self, payload=b'{"ready": true}', failure=None):
        self.payload = payload
        self.failure = failure
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        if self.failure:
            raise self.failure
        return HealthResponse(self.payload)


class ReleaseGatesTest(unittest.TestCase):
    def test_health_requires_explicit_ready_from_every_endpoint(self):
        opener = HealthOpener()
        self.assertTrue(all(endpoint_readiness('https://public.example', opener).values()))
        self.assertEqual(len(opener.requests), len(ENDPOINTS))
        for request in opener.requests:
            self.assertEqual(request.method, 'GET')
            self.assertTrue(request.full_url.endswith('?health=1'))
            self.assertNotIn('Authorization', request.headers)
            self.assertIsNone(request.data)

    def test_liveness_malformed_body_redirect_and_unconfigured_health_fail_closed(self):
        for opener in (HealthOpener(b'{"ok":true}'), HealthOpener(b'{"ready":"true"}'),
                       HealthOpener(b'invalid'), HealthOpener(b'[]'),
                       HealthOpener(failure=urllib.error.HTTPError('redacted', 302, '', {}, None)),
                       HealthOpener(failure=urllib.error.HTTPError('redacted', 503, '', {}, None))):
            with self.subTest(opener=opener):
                self.assertFalse(any(endpoint_readiness('https://public.example', opener).values()))
        for base in ('', 'http://public.example', 'https://user:password@public.example',
                     'https://public.example?token=private'):
            opener = HealthOpener()
            self.assertFalse(any(endpoint_readiness(base, opener).values()))
            self.assertFalse(opener.requests)

    def test_evidence_requires_fresh_signed_matching_package_and_purchase_restore_proof(self):
        now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'candidate.pkg'
            package.write_bytes(b'offline signed candidate fixture')
            path = root / 'evidence.json'
            original = dict(schemaVersion=1, version='22.17.35', build='525',
                            sourceRevision='a' * 40, sourceFingerprint='b' * 64,
                            testedAt=now.isoformat(), candidate={
                                'signatureVerified': True, 'sandboxEntitlementsVerified': True,
                                'storeEditionVerified': True,
                                'signedPackageSha256': hashlib.sha256(package.read_bytes()).hexdigest()},
                            checks={key: {'passed': True, 'proof': 'private evidence reference'}
                                    for key in SMOKE_CHECKS})
            run = subprocess.CompletedProcess([], 0, 'a' * 40 + '\n', '')
            with patch('mac_app_store_release_gates.subprocess.run', return_value=run), patch(
                    'mac_app_store_release_gates.source_fingerprint', return_value='b' * 64):
                def check(evidence):
                    path.write_text(json.dumps(evidence))
                    return review_evidence('22.17.35', '525', package, path, now)

                self.assertTrue(all(check(original).values()))
                for key, value in (('build', '481'), ('sourceFingerprint', 'c' * 64),
                                   ('sourceRevision', 'd' * 40),
                                   ('testedAt', (now - timedelta(hours=49)).isoformat()),
                                   ('testedAt', (now + timedelta(minutes=1)).isoformat())):
                    evidence = {**original, key: value}
                    self.assertFalse(any(check(evidence).values()))
                evidence = json.loads(json.dumps(original))
                evidence['checks']['sandboxRestore']['proof'] = ''
                result = check(evidence)
                self.assertFalse(result['purchase_restore_evidence'])
                self.assertFalse(result['review_smoke_evidence'])
                evidence = json.loads(json.dumps(original))
                evidence['candidate']['signatureVerified'] = False
                self.assertFalse(check(evidence)['fresh_signed_candidate_evidence'])
                check(original)
                package.write_bytes(b'different package with the same version')
                self.assertFalse(review_evidence('22.17.35', '525', package, path, now)[
                    'fresh_signed_candidate_evidence'])

    def test_absent_evidence_never_passes(self):
        with patch.dict('os.environ', {}, clear=True):
            self.assertFalse(any(review_evidence('22.17.35', '525').values()))

    def test_each_missing_operational_proof_fails_closed_and_cannot_invent_a_signed_candidate(self):
        now = datetime(2026, 10, 29, 12, tzinfo=timezone.utc)
        original = dict(schemaVersion=1, version='22.17.36', build='526',
                        sourceRevision='a' * 40, sourceFingerprint='b' * 64,
                        testedAt=now.isoformat(), candidate={
                            'signatureVerified': True, 'sandboxEntitlementsVerified': True,
                            'storeEditionVerified': True, 'signedPackageSha256': 'c' * 64},
                        checks={key: {'passed': True, 'proof': 'offline proof reference'}
                                for key in SMOKE_CHECKS})
        run = subprocess.CompletedProcess([], 0, 'a' * 40 + '\n', '')
        with tempfile.TemporaryDirectory() as directory, patch(
                'mac_app_store_release_gates.subprocess.run', return_value=run), patch(
                'mac_app_store_release_gates.source_fingerprint', return_value='b' * 64):
            path = Path(directory) / 'evidence.json'
            for key in OPERATIONAL_CHECKS:
                for failure in ('missing', 'not-passed', 'no-proof'):
                    evidence = json.loads(json.dumps(original))
                    if failure == 'missing':
                        del evidence['checks'][key]
                    elif failure == 'not-passed':
                        evidence['checks'][key]['passed'] = False
                    else:
                        evidence['checks'][key]['proof'] = ''
                    path.write_text(json.dumps(evidence))
                    result = review_evidence('22.17.36', '526', evidence_path=path, now=now)
                    with self.subTest(key=key, failure=failure):
                        self.assertFalse(result[key])
                        self.assertFalse(result['review_smoke_evidence'])
                        self.assertFalse(result['fresh_signed_candidate_evidence'])

    def test_source_fingerprint_tracks_uncommitted_and_new_shipped_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '--quiet', str(root)], check=True, capture_output=True)
            (root / 'lib').mkdir()
            source = root / 'lib/main.dart'
            source.write_text('original source')
            subprocess.run(['git', 'add', 'lib/main.dart'], cwd=root, check=True, capture_output=True)
            initial = source_fingerprint(root)
            source.write_text('changed source at the same HEAD')
            changed = source_fingerprint(root)
            self.assertNotEqual(initial, changed)
            (root / 'lib/new.dart').write_text('untracked shipped source')
            added = source_fingerprint(root)
            self.assertNotEqual(changed, added)
            (root / 'operator-evidence.json').write_text('non-shipped review evidence')
            self.assertEqual(added, source_fingerprint(root))


if __name__ == '__main__':
    unittest.main()
