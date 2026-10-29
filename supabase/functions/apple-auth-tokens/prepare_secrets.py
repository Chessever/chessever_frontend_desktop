#!/usr/bin/env python3
"""Prepare initial SIWA server secrets locally; never deploy or print a value."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys


def outside_repository(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    repository = Path(__file__).resolve().parents[3]
    if resolved == repository or repository in resolved.parents:
        raise ValueError("Key and output files must be outside the source repository.")
    return resolved


def validate_private_key(pem: bytes) -> None:
    # Derive only public bytes. Never emit openssl's output or error details.
    result = subprocess.run(
        ["openssl", "pkey", "-pubout", "-outform", "DER"],
        input=pem, capture_output=True, check=False, timeout=10,
    )
    p256_spki_prefix = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
    if result.returncode or not result.stdout.startswith(p256_spki_prefix):
        raise ValueError("Expected an unencrypted PKCS#8 EC P-256 signing key.")
    if not pem.startswith(b"-----BEGIN PRIVATE KEY-----"):
        raise ValueError("Expected an unencrypted PKCS#8 EC P-256 signing key.")


def write_initial_secrets(args: argparse.Namespace) -> None:
    if not args.confirm_sign_in_with_apple_key:
        raise ValueError("Confirm the key's Sign in with Apple capability; App Store Connect API keys are not SIWA keys.")
    key_path = outside_repository(Path(args.key_file))
    output = outside_repository(Path(args.output))
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id) or not re.fullmatch(r"[A-Z0-9]{10}", args.key_id):
        raise ValueError("Team ID and SIWA Key ID must each contain 10 uppercase letters/digits.")
    clients = [value.strip() for value in args.client_ids.split(",") if value.strip()]
    if not clients or any(not re.fullmatch(r"[A-Za-z0-9.-]+", value) for value in clients):
        raise ValueError("Supply the exact Apple-enabled bundle/Services IDs, comma-separated.")
    if key_path.stat().st_size > 16384:
        raise ValueError("Signing key file is too large.")
    pem = key_path.read_bytes()
    validate_private_key(pem)
    values = {
        "APPLE_TEAM_ID": args.team_id,
        "APPLE_KEY_ID": args.key_id,
        "APPLE_PRIVATE_KEY": pem.decode("ascii").strip().replace("\n", "\\n"),
        "APPLE_CLIENT_IDS": ",".join(clients),
        "APPLE_REDIRECT_URIS": "{}",
        "APPLE_TOKEN_ACTIVE_KEY_ID": "initial-v1",
        "APPLE_TOKEN_ENCRYPTION_KEYS": json.dumps({"initial-v1": base64.b64encode(secrets.token_bytes(32)).decode("ascii")}, separators=(",", ":")),
        "APPLE_REVOCATION_WORKER_SECRET": secrets.token_urlsafe(48),
    }
    if any("'" in value or "\n" in value or "\r" in value for value in values.values()):
        raise ValueError("Invalid secret file format.")
    content = "".join(f"{name}='{value}'\n" for name, value in values.items())
    # O_EXCL also rejects symlinks and prevents accidental rotation/overwrite.
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-file", required=True, help="Existing Apple SIWA .p8 outside this repository")
    parser.add_argument("--output", required=True, help="New private env file outside this repository")
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--client-ids", required=True)
    parser.add_argument("--confirm-sign-in-with-apple-key", action="store_true")
    args = parser.parse_args()
    try:
        write_initial_secrets(args)
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError):
        # Do not format an exception that could contain key material or paths.
        print("Secrets were not prepared. Check SIWA capability, IDs, external file paths, and that output does not exist.", file=sys.stderr)
        return 1
    print("Prepared a new mode-0600 server secrets file. No secrets were uploaded or displayed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
