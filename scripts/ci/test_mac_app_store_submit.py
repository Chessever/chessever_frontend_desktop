"""Exercise the real submission wrapper with a fake App Store CLI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('mac_app_store_submit.sh')


class MacAppStoreSubmitTest(unittest.TestCase):
    def run_submit(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'ChessEver-Mac-App-Store.pkg').write_bytes(b'signed package fixture')
            for name in ('app-store-connect', 'python3'):
                stub = root / name
                stub.write_text(f'#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
                stub.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       STORE_OUTPUT=str(root), RELEASE_REF='refs/heads/main')
            env.update(overrides)
            result = subprocess.run(['bash', str(SCRIPT)], env=env,
                                    text=True, capture_output=True)
            return result, json.loads(result.stdout) if result.returncode == 0 else []

    def test_review_is_default_and_always_manual(self):
        result, args = self.run_submit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(args[0].endswith('app_store_review.py'))
        self.assertEqual(args[args.index('--platform') + 1], 'MAC_OS')
        self.assertEqual(args[args.index('--release-type') + 1], 'MANUAL')
        self.assertNotIn('--cancel-previous-submissions', args)
        self.assertEqual(args[args.index('--replace-pending') + 1], 'false')

    def test_pending_review_replacement_is_explicit(self):
        result, args = self.run_submit(REPLACE_PENDING_REVIEW='true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index('--replace-pending') + 1], 'true')
        self.assertEqual(args[args.index('--release-type') + 1], 'MANUAL')

    def test_upload_only_does_not_mutate_review(self):
        result, args = self.run_submit(SUBMIT_REVIEW='false')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('--app-store', args)
        self.assertNotIn('--cancel-previous-submissions', args)
        self.assertIn('--silent', args)

    def test_wrong_branch_and_invalid_options_never_call_cli(self):
        for options in ({'RELEASE_REF': 'refs/heads/dev'},
                        {'SUBMIT_REVIEW': 'false', 'REPLACE_PENDING_REVIEW': 'true'},
                        {'SUBMIT_REVIEW': 'invalid'}):
            with self.subTest(options=options):
                result, args = self.run_submit(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(args, [])


if __name__ == '__main__':
    unittest.main()
