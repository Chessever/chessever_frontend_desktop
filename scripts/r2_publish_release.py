#!/usr/bin/env python3
"""Publish a validated desktop_updater release to private Cloudflare R2.

Immutable archive payloads and versioned installers are uploaded first, stable
aliases second, and updater manifests last. Every PUT supplies SHA-256 and is
verified with HeadObject before publication can advance.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import mimetypes
import os
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote

import boto3
from botocore.exceptions import ClientError


IMMUTABLE_CACHE = "public, max-age=31536000, s-maxage=31536000, immutable"
MUTABLE_CACHE = "public, max-age=300, s-maxage=300, stale-while-revalidate=60"
MAX_SINGLE_PUT_BYTES = 5 * 1024**3
PLATFORM_PATTERN = re.compile(r"^(macos|macos-x64|windows|linux)$")
VERSION_PATTERN = re.compile(
    r"^(?P<version>\d+\.\d+\.\d+)\+(?P<build>[1-9]\d*)$"
)


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def sha256(path: Path) -> tuple[str, str]:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest(), base64.b64encode(digest.digest()).decode("ascii")


def content_type(path: Path) -> str:
    overrides = {
        ".dmg": "application/x-apple-diskimage",
        ".exe": "application/vnd.microsoft.portable-executable",
        ".deb": "application/vnd.debian.binary-package",
        ".pgn": "application/x-chess-pgn",
    }
    return overrides.get(path.suffix.lower()) or (
        mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    )


class R2Publisher:
    def __init__(self) -> None:
        account_id = required_env("R2_ACCOUNT_ID")
        self.bucket = os.environ.get("R2_BUCKET", "chessever-releases").strip()
        self.client = boto3.client(
            "s3",
            endpoint_url=f"https://{account_id}.r2.cloudflarestorage.com",
            region_name="auto",
            aws_access_key_id=required_env("R2_ACCESS_KEY_ID"),
            aws_secret_access_key=required_env("R2_SECRET_ACCESS_KEY"),
        )

    def put_verified(
        self,
        path: Path,
        key: str,
        *,
        cache_control: str,
        if_match: str | None = None,
        if_none_match: str | None = None,
    ) -> str:
        size = path.stat().st_size
        if size > MAX_SINGLE_PUT_BYTES:
            raise RuntimeError(
                f"{path} is larger than R2's 5 GiB single-PUT limit; "
                "add a checksum-aware multipart uploader before publishing it"
            )
        digest_hex, digest_b64 = sha256(path)
        request: dict[str, Any] = {
            "Bucket": self.bucket,
            "Key": key,
            "Body": path.open("rb"),
            "ContentLength": size,
            "ContentType": content_type(path),
            "CacheControl": cache_control,
            "ChecksumAlgorithm": "SHA256",
            "ChecksumSHA256": digest_b64,
            "Metadata": {"sha256": digest_hex},
        }
        if if_match:
            request["IfMatch"] = if_match
        if if_none_match:
            request["IfNoneMatch"] = if_none_match
        try:
            response = self.client.put_object(**request)
        finally:
            request["Body"].close()

        remote = self.client.head_object(
            Bucket=self.bucket,
            Key=key,
            ChecksumMode="ENABLED",
        )
        if int(remote["ContentLength"]) != size:
            raise RuntimeError(f"remote size mismatch for {key}")
        remote_checksum = remote.get("ChecksumSHA256")
        remote_metadata_checksum = remote.get("Metadata", {}).get("sha256")
        if remote_checksum != digest_b64 or remote_metadata_checksum != digest_hex:
            raise RuntimeError(f"remote SHA-256 mismatch for {key}")
        print(f"verified sha256={digest_hex} r2://{self.bucket}/{key}")
        return str(response.get("ETag") or remote["ETag"])

    def put_immutable_verified(self, path: Path, key: str) -> None:
        size = path.stat().st_size
        digest_hex, digest_b64 = sha256(path)
        try:
            remote = self.client.head_object(
                Bucket=self.bucket,
                Key=key,
                ChecksumMode="ENABLED",
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") not in {
                "404",
                "NoSuchKey",
                "NotFound",
            }:
                raise
        else:
            if (
                int(remote["ContentLength"]) == size
                and remote.get("ChecksumSHA256") == digest_b64
                and remote.get("Metadata", {}).get("sha256") == digest_hex
            ):
                print(f"reusing verified immutable r2://{self.bucket}/{key}")
                return
            raise RuntimeError(
                f"refusing to overwrite immutable key with different bytes: {key}"
            )

        self.put_verified(
            path,
            key,
            cache_control=IMMUTABLE_CACHE,
            if_none_match="*",
        )

    def get_json(self, key: str) -> tuple[dict[str, Any] | None, str | None]:
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=key)
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") in {
                "404",
                "NoSuchKey",
                "NotFound",
            }:
                return None, None
            raise
        with response["Body"] as body:
            return json.loads(body.read()), str(response["ETag"])

    def put_json_atomic(
        self,
        key: str,
        transform: Any,
        scratch: Path,
    ) -> dict[str, Any]:
        for attempt in range(5):
            current, etag = self.get_json(key)
            updated = transform(current)
            scratch.write_text(
                json.dumps(updated, indent=2, sort_keys=False) + "\n",
                encoding="utf-8",
            )
            try:
                self.put_verified(
                    scratch,
                    key,
                    cache_control=MUTABLE_CACHE,
                    if_match=etag,
                    if_none_match="*" if etag is None else None,
                )
                return updated
            except ClientError as error:
                status = error.response.get("ResponseMetadata", {}).get(
                    "HTTPStatusCode"
                )
                if status not in {409, 412} or attempt == 4:
                    raise
                print(f"{key} changed concurrently; merging again", file=sys.stderr)
        raise RuntimeError(f"unable to publish {key} atomically")

    def delete_prefix(self, prefix: str) -> None:
        token: str | None = None
        while True:
            request: dict[str, Any] = {
                "Bucket": self.bucket,
                "Prefix": prefix,
            }
            if token:
                request["ContinuationToken"] = token
            response = self.client.list_objects_v2(**request)
            objects = [{"Key": item["Key"]} for item in response.get("Contents", [])]
            if objects:
                self.client.delete_objects(
                    Bucket=self.bucket,
                    Delete={"Objects": objects, "Quiet": True},
                )
            if not response.get("IsTruncated"):
                return
            token = response["NextContinuationToken"]

    def list_keys(self, prefix: str) -> list[str]:
        keys: list[str] = []
        token: str | None = None
        while True:
            request: dict[str, Any] = {
                "Bucket": self.bucket,
                "Prefix": prefix,
            }
            if token:
                request["ContinuationToken"] = token
            response = self.client.list_objects_v2(**request)
            keys.extend(str(item["Key"]) for item in response.get("Contents", []))
            if not response.get("IsTruncated"):
                return keys
            token = response["NextContinuationToken"]


def archive_stats(archive_dir: Path) -> tuple[int, int, str]:
    hashes_path = archive_dir / "hashes.json"
    entries = json.loads(hashes_path.read_text(encoding="utf-8"))
    if not isinstance(entries, list) or not entries:
        raise RuntimeError("hashes.json must contain a non-empty list")
    total = 0
    for entry in entries:
        relative = str(entry["path"]).replace("\\", "/")
        if PurePosixPath(relative).is_absolute() or ".." in PurePosixPath(relative).parts:
            raise RuntimeError(f"unsafe archive path: {relative}")
        path = archive_dir.joinpath(*PurePosixPath(relative).parts)
        if not path.is_file():
            raise RuntimeError(f"archive file is missing: {relative}")
        actual = path.stat().st_size
        expected = int(entry.get("length") or actual)
        if actual != expected:
            raise RuntimeError(f"archive size mismatch: {relative}")
        total += actual
    hashes_digest, _ = sha256(hashes_path)
    return len(entries), total, hashes_digest


def version_order(item: dict[str, Any]) -> tuple[int, int, int, int]:
    major, minor, patch = (int(part) for part in str(item["version"]).split("."))
    return major, minor, patch, int(item["shortVersion"])


def publish(args: argparse.Namespace) -> None:
    platform_match = PLATFORM_PATTERN.fullmatch(args.platform)
    version_match = VERSION_PATTERN.fullmatch(args.release_version)
    if not platform_match or not version_match:
        raise RuntimeError("invalid platform or release version")

    archive_dir = Path(args.archive_dir).resolve()
    installer = Path(args.installer).resolve()
    if not archive_dir.is_dir() or not installer.is_file():
        raise RuntimeError("archive directory and installer must exist")
    expected_archive = f"{args.release_version}-{args.platform}"
    if archive_dir.name != expected_archive:
        raise RuntimeError(
            f"archive directory must be named {expected_archive}, got {archive_dir.name}"
        )

    file_count, total_bytes, hashes_digest = archive_stats(archive_dir)
    publisher = R2Publisher()
    archive_prefix = f"desktop/archive/{archive_dir.name}"

    # Phase 1: immutable versioned payload.
    for path in sorted(item for item in archive_dir.rglob("*") if item.is_file()):
        relative = path.relative_to(archive_dir).as_posix()
        publisher.put_immutable_verified(path, f"{archive_prefix}/{relative}")
    publisher.put_immutable_verified(
        installer,
        f"desktop/downloads/{args.versioned_installer_name}",
    )

    release_metadata = {
        "schema": 2,
        "platform": args.platform,
        "channel": "stable",
        "archiveDir": archive_dir.name,
        "version": version_match.group("version"),
        "shortVersion": int(version_match.group("build")),
        "order": [
            *(int(part) for part in version_match.group("version").split(".")),
            int(version_match.group("build")),
        ],
        "date": dt.date.today().isoformat(),
        "publishedAt": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "mandatory": False,
        "changes": [
            {
                "type": "New",
                "message": f"Chessever {args.release_version} is available.",
            }
        ],
        "fileCount": file_count,
        "totalBytes": total_bytes,
        "hashesSha256": hashes_digest,
    }
    metadata_path = Path(args.scratch_dir) / f"{archive_dir.name}.release.json"
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(
        json.dumps(release_metadata, indent=2) + "\n",
        encoding="utf-8",
    )
    publisher.put_verified(
        metadata_path,
        f"desktop/archive/{metadata_path.name}",
        cache_control=IMMUTABLE_CACHE,
    )

    # Phase 2: mutable stable installer alias.
    publisher.put_verified(
        installer,
        f"desktop/downloads/{args.stable_installer_name}",
        cache_control=MUTABLE_CACHE,
    )

    item = {
        "version": release_metadata["version"],
        "shortVersion": release_metadata["shortVersion"],
        "changes": release_metadata["changes"],
        "date": release_metadata["date"],
        "mandatory": False,
        "url": (
            "https://chessever.com/updates/desktop/archive/"
            f"{quote(archive_dir.name, safe='._-')}"
        ),
        "platform": args.platform,
    }
    aliases = [item]
    if args.platform == "macos":
        aliases.append({**item, "platform": "macos-arm64"})

    removed_archive_dirs: set[str] = set()

    def merge_app_archive(current: dict[str, Any] | None) -> dict[str, Any]:
        if current is None:
            raise RuntimeError(
                "desktop/app-archive.json is missing in R2; migrate and verify "
                "the existing release tree before the first R2 publish"
            )
        alias_platforms = {entry["platform"] for entry in aliases}
        items = [
            existing
            for existing in current.get("items", [])
            if not (
                existing.get("platform") in alias_platforms
                and existing.get("version") == item["version"]
                and existing.get("shortVersion") == item["shortVersion"]
            )
        ]
        items.extend(aliases)
        kept: list[dict[str, Any]] = []
        for platform in sorted({str(entry.get("platform")) for entry in items}):
            candidates = sorted(
                [entry for entry in items if entry.get("platform") == platform],
                key=version_order,
                reverse=True,
            )
            kept.extend(candidates[:2])
            for stale in candidates[2:]:
                url = str(stale.get("url") or "")
                marker = "/desktop/archive/"
                if marker in url:
                    removed_archive_dirs.add(url.split(marker, 1)[1].split("/", 1)[0])
        kept.sort(key=version_order, reverse=True)
        return {
            "appName": "Chessever",
            "description": "Chessever desktop update archive",
            "items": kept,
        }

    scratch = Path(args.scratch_dir)
    app_archive = publisher.put_json_atomic(
        "desktop/app-archive.json",
        merge_app_archive,
        scratch / "app-archive.json",
    )

    def merge_latest(current: dict[str, Any] | None) -> dict[str, Any]:
        result = current or {
            "schema": 2,
            "channel": "stable",
            "appArchiveUrl": (
                "https://chessever.com/updates/desktop/app-archive.json"
            ),
            "platforms": {},
        }
        platforms = dict(result.get("platforms") or {})
        latest_value = {
            "version": release_metadata["version"],
            "shortVersion": release_metadata["shortVersion"],
            "archiveDir": archive_dir.name,
            "url": item["url"],
            "date": release_metadata["date"],
            "mandatory": False,
            "fileCount": file_count,
            "totalBytes": total_bytes,
        }
        platforms[args.platform] = latest_value
        if args.platform == "macos":
            platforms["macos-arm64"] = latest_value
        return {**result, "platforms": platforms}

    # Phase 3: manifests. app-archive was committed atomically above and is
    # re-verified; latest.json follows with its own optimistic concurrency.
    publisher.put_json_atomic(
        "desktop/latest.json",
        merge_latest,
        scratch / "latest.json",
    )

    # Prune only objects no longer referenced by the successfully committed
    # manifest. Never remove the archive just published.
    referenced = {
        str(entry["url"]).split("/desktop/archive/", 1)[1]
        for entry in app_archive["items"]
        if "/desktop/archive/" in str(entry.get("url"))
    }
    for stale in sorted(removed_archive_dirs - referenced - {archive_dir.name}):
        publisher.delete_prefix(f"desktop/archive/{stale}/")
        publisher.client.delete_object(
            Bucket=publisher.bucket,
            Key=f"desktop/archive/{stale}.release.json",
        )

    installer_patterns = {
        "windows": re.compile(
            r"^desktop/downloads/Chessever-(\d+\.\d+\.\d+)\+(\d+)-Setup\.exe$"
        ),
        "macos": re.compile(
            r"^desktop/downloads/Chessever-(\d+\.\d+\.\d+)\+(\d+)\.dmg$"
        ),
        "macos-x64": re.compile(
            r"^desktop/downloads/Chessever-(\d+\.\d+\.\d+)\+(\d+)-intel\.dmg$"
        ),
        "linux": re.compile(
            r"^desktop/downloads/Chessever-(\d+\.\d+\.\d+)\+(\d+)-amd64\.deb$"
        ),
    }
    candidates: list[tuple[tuple[int, int, int, int], str]] = []
    pattern = installer_patterns[args.platform]
    for key in publisher.list_keys("desktop/downloads/"):
        match = pattern.fullmatch(key)
        if not match:
            continue
        major, minor, patch = (int(part) for part in match.group(1).split("."))
        candidates.append(((major, minor, patch, int(match.group(2))), key))
    for _, stale_key in sorted(candidates, reverse=True)[2:]:
        publisher.client.delete_object(Bucket=publisher.bucket, Key=stale_key)

    print(f"published {args.platform} {args.release_version} to R2")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True)
    parser.add_argument("--release-version", required=True)
    parser.add_argument("--archive-dir", required=True)
    parser.add_argument("--installer", required=True)
    parser.add_argument("--versioned-installer-name", required=True)
    parser.add_argument("--stable-installer-name", required=True)
    parser.add_argument("--scratch-dir", required=True)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        publish(parse_args())
    except Exception as error:  # noqa: BLE001 - CI entrypoint emits one failure
        print(f"R2 publish failed: {error}", file=sys.stderr)
        raise SystemExit(1)
