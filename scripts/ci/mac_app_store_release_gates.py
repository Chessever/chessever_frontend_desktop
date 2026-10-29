"""Non-mutating endpoint probes and candidate-bound smoke evidence validation."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from app_store_review import NoRedirect

ROOT = Path(__file__).resolve().parents[2]
ENDPOINTS = ('apple-auth-tokens', 'apple-auth-revocations',
             'apple-auth-notifications', 'delete-account')
OPERATIONAL_CHECKS = ('appPrivacyInventory', 'subscriptionServerNotifications',
                      'deletionOperations', 'aiReportOperations')
SMOKE_CHECKS = ('nativeAppleSignIn', 'inAppGoogleSignIn', 'guestDeletion',
                'accountDeletion', 'aiSharingConsent', 'monthlySandboxPurchase',
                'annualSandboxPurchase', 'sandboxRestore', 'appleTokenCapture',
                'appleRevocation', 'appleNotification', 'aiSafety') + OPERATIONAL_CHECKS


def endpoint_readiness(base=None, opener=None):
    """GET health only; never register, delete, drain, revoke or send an event.

    Health contract: each function accepts GET ?health=1 and responds 200 JSON
    {"ready": true} only after checking its server configuration and schema.
    A 200 liveness response, 401, 405, redirect or unavailable probe is not ready.
    """
    checks = {'apple_endpoint_' + name.replace('-', '_') + '_ready': False
              for name in ENDPOINTS}
    base = base if base is not None else os.environ.get('SUPABASE_URL', '')
    url = urllib.parse.urlsplit(base)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password
            or url.query or url.fragment or url.path not in ('', '/')):
        return checks
    opener = opener or urllib.request.build_opener(NoRedirect())
    for endpoint, key in zip(ENDPOINTS, checks):
        request = urllib.request.Request(
            base.rstrip('/') + '/functions/v1/' + endpoint + '?health=1',
            headers={'Accept': 'application/json'}, method='GET')
        try:
            with opener.open(request, timeout=15) as response:
                raw = response.read(16385)
                if response.status == 200 and len(raw) <= 16384:
                    checks[key] = json.loads(raw).get('ready') is True
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, AttributeError):
            pass  # Never echo response bodies, URLs or environment values.
    return checks


def source_fingerprint(root=ROOT):
    """Include uncommitted/new shipped sources, rather than trusting HEAD alone."""
    result = subprocess.run([
        'git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--',
        'lib', 'macos', 'assets', 'third_party', 'pubspec.yaml', 'pubspec.lock',
        'scripts/build_mac_app_store.sh', 'scripts/prepare_mac_app_store_engines.py',
    ], cwd=root, check=True, capture_output=True)
    digest = hashlib.sha256()
    for name in sorted(set(result.stdout.split(b'\0')) - {b''}):
        path = root / os.fsdecode(name)
        digest.update(name + b'\0')
        if path.is_file():
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        else:
            digest.update(b'missing')
    return digest.hexdigest()


def review_evidence(version, build, package=None, evidence_path=None, now=None):
    checks = dict(fresh_signed_candidate_evidence=False, purchase_restore_evidence=False,
                  review_smoke_evidence=False)
    checks.update({key: False for key in OPERATIONAL_CHECKS})
    evidence_path = evidence_path or os.environ.get('MAC_APP_STORE_REVIEW_EVIDENCE')
    if not evidence_path:
        return checks
    try:
        evidence = json.loads(Path(evidence_path).read_text())
        tested = datetime.fromisoformat(evidence['testedAt'].replace('Z', '+00:00'))
        now = now or datetime.now(timezone.utc)
        revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT,
                                  check=True, capture_output=True, text=True).stdout.strip()
        current = (evidence.get('schemaVersion') == 1 and evidence.get('version') == version
                   and evidence.get('build') == build and evidence.get('sourceRevision') == revision
                   and evidence.get('sourceFingerprint') == source_fingerprint()
                   and timedelta(0) <= now - tested <= timedelta(hours=48))
        candidate = evidence.get('candidate', {})
        digest = candidate.get('signedPackageSha256', '')
        matches_package = bool(package and Path(package).is_file()
                               and re.fullmatch('[0-9a-f]{64}', digest)
                               and hashlib.sha256(Path(package).read_bytes()).hexdigest() == digest)
        checks['fresh_signed_candidate_evidence'] = bool(
            current and matches_package and candidate.get('signatureVerified') is True
            and candidate.get('sandboxEntitlementsVerified') is True
            and candidate.get('storeEditionVerified') is True)
        results = evidence.get('checks', {})

        def passed(key):
            row = results.get(key, {})
            return isinstance(row, dict) and row.get('passed') is True and bool(
                isinstance(row.get('proof'), str) and row['proof'].strip())

        checks['purchase_restore_evidence'] = bool(current and all(passed(key) for key in (
            'monthlySandboxPurchase', 'annualSandboxPurchase', 'sandboxRestore')))
        checks.update({key: bool(current and passed(key)) for key in OPERATIONAL_CHECKS})
        checks['review_smoke_evidence'] = bool(current and all(passed(key) for key in SMOKE_CHECKS))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        pass
    return checks
