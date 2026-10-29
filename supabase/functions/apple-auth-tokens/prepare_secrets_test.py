"""Offline tests: ephemeral keys only; no secrets/deployment calls."""
import argparse
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("prepare_secrets", Path(__file__).with_name("prepare_secrets.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareSecretsTest(unittest.TestCase):
    def test_initial_file_is_private_never_printed_and_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            generated = subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:prime256v1"], check=True, capture_output=True).stdout
            key_file = root / "ephemeral.p8"
            key_file.write_bytes(generated)
            args = argparse.Namespace(key_file=str(key_file), output=str(root / "server.env"), team_id="TESTTEAM00", key_id="TESTKEY000", client_ids="test.example.app", confirm_sign_in_with_apple_key=True)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                module.write_initial_secrets(args)
            self.assertEqual(output.getvalue(), "")
            result = Path(args.output)
            self.assertEqual(stat.S_IMODE(result.stat().st_mode), 0o600)
            text = result.read_text()
            self.assertIn("APPLE_PRIVATE_KEY=", text)
            self.assertIn("APPLE_TOKEN_ENCRYPTION_KEYS=", text)
            self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY", text)
            with self.assertRaises(FileExistsError):
                module.write_initial_secrets(args)
            self.assertEqual(text, result.read_text())

    def test_repository_paths_and_unconfirmed_capability_are_rejected(self):
        with self.assertRaises(ValueError):
            module.outside_repository(Path(__file__).with_name("forbidden.env"))
        args = argparse.Namespace(confirm_sign_in_with_apple_key=False)
        with self.assertRaises(ValueError):
            module.write_initial_secrets(args)

    def test_invalid_or_wrong_curve_key_is_rejected(self):
        with self.assertRaises(ValueError):
            module.validate_private_key(b"not a private key")
        other_curve = subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:secp384r1"], check=True, capture_output=True).stdout
        with self.assertRaises(ValueError):
            module.validate_private_key(other_curve)


if __name__ == "__main__":
    unittest.main()
