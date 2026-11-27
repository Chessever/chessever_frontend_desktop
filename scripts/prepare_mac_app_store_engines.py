#!/usr/bin/env python3
"""Prepare pinned, verified engine code and model data for the store bundle."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/mac-app-store/engines").resolve()
root.mkdir(parents=True, exist_ok=True)
cache = root / "downloads"
cache.mkdir(exist_ok=True)


def fetch(name, urls, digest):
    """Downloads the first source whose bytes match [digest].

    [urls] is one URL or an ordered list of mirrors. Every source is held to
    the same pinned SHA-256, so a mirror can never change what ships.
    """
    target = cache / name
    if target.exists() and hashlib.file_digest(target.open("rb"), "sha256").hexdigest() == digest:
        return target
    partial = target.with_suffix(target.suffix + ".partial")
    failures = []
    for url in [urls] if isinstance(urls, str) else urls:
        try:
            subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(partial), url], check=True)
        except subprocess.CalledProcessError as error:
            failures.append(f"{url}: curl exit {error.returncode}")
            continue
        actual = hashlib.file_digest(partial.open("rb"), "sha256").hexdigest()
        if actual != digest:
            failures.append(f"{url}: checksum mismatch")
            continue
        partial.replace(target)
        return target
    raise RuntimeError(f"No verified source for {name}: " + "; ".join(failures))


# Keep this pin aligned with lib/desktop/services/play/engine_catalog.dart.
# Stockfish 19 publishes one universal (arm64 + x86_64) macOS executable. Ship
# it whole: its x86_64 slice reads the network from the arm64 slice.
stockfish_name = "stockfish-macos-universal"
archive = fetch(
    stockfish_name + ".tar.gz",
    f"https://github.com/official-stockfish/Stockfish/releases/download/sf_19/{stockfish_name}.tar.gz",
    "a1f0e3bcc5a6927a11fe6fc8e54a779754645f3c2bae2cf13420fd1957adaa77",
)
with tarfile.open(archive) as package:
    with package.extractfile("stockfish/" + stockfish_name) as source, (root / "stockfish").open("wb") as destination:
        shutil.copyfileobj(source, destination)
    for member in package.getmembers():
        if member.isfile() and Path(member.name).name.lower() in {"copying.txt", "copying", "license"}:
            with package.extractfile(member) as source, (root / "Stockfish-LICENSE.txt").open("wb") as destination:
                shutil.copyfileobj(source, destination)

for name, url, digest in [
    ("lc0", "https://github.com/LeelaChessZero/lc0/releases/download/v0.32.0/lc0-v0.32.0-macos_12.6.1", "2d276ad784fc0a9a00dc6e0a71d0340fb8805acf27a1874c769f3d8e7c60c81e"),
    ("weights.pb.gz", "https://storage.lczero.org/files/networks-contrib/t1-256x10-distilled-swa-2432500.pb.gz", "bc27a6cae8ad36f2b9a80a6ad9dabb0d6fda25b1e7f481a79bc359e14f563406"),
    # Maia downloads only from our own content-addressed copy, never from
    # maiachess.com (a Vercel bot checkpoint answers non-browser clients with
    # HTTP 429). Same rule as the Play catalog in engine_catalog.dart.
    ("maia3_simplified.onnx",
     "https://chessever.com/updates/engines/maia3/405bf76c15727dad8728b352c06a8f3c1b80fb2760e8d666b32485c63d75b856/maia3_simplified.onnx",
     "405bf76c15727dad8728b352c06a8f3c1b80fb2760e8d666b32485c63d75b856"),
]:
    shutil.copyfile(fetch(name, url, digest), root / name)
for name in ("stockfish", "lc0"):
    (root / name).chmod(0o755)
    architectures = subprocess.check_output(["lipo", "-archs", str(root / name)], text=True).split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise RuntimeError(f"{name} is missing a required Mac architecture")

manifest = {name: hashlib.file_digest((root / name).open("rb"), "sha256").hexdigest()
            for name in ("stockfish", "lc0", "weights.pb.gz", "maia3_simplified.onnx")}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Verified universal Stockfish and Leela, plus their bundled model data.")
