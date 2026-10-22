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


def fetch(name, url, digest):
    target = cache / name
    if not target.exists() or hashlib.file_digest(target.open("rb"), "sha256").hexdigest() != digest:
        partial = target.with_suffix(target.suffix + ".partial")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(partial), url], check=True)
        actual = hashlib.file_digest(partial.open("rb"), "sha256").hexdigest()
        if actual != digest:
            raise RuntimeError(f"Checksum mismatch for {name}")
        partial.replace(target)
    return target


# Keep these pins aligned with lib/desktop/services/play/engine_catalog.dart.
stockfish = []
for arch, name, digest in [
    ("arm64", "stockfish-macos-m1-apple-silicon", "4d77c4aa3ad9bd1ea8111f2ac5a4620fe7ebf998d6893bf828d49ccd579c8cb0"),
    ("x86_64", "stockfish-macos-x86-64-avx2", "41d30e0860ad924a6ceb422c3a36eba43bbe5ae87d3310840da50e71c53f35d9"),
]:
    archive = fetch(name + ".tar", f"https://github.com/official-stockfish/Stockfish/releases/download/sf_18/{name}.tar", digest)
    executable = root / f"stockfish-{arch}"
    with tarfile.open(archive) as package:
        with package.extractfile("stockfish/" + name) as source, executable.open("wb") as destination:
            shutil.copyfileobj(source, destination)
        for member in package.getmembers():
            if member.isfile() and Path(member.name).name.lower() in {"copying.txt", "copying", "license"}:
                with package.extractfile(member) as source, (root / "Stockfish-LICENSE.txt").open("wb") as destination:
                    shutil.copyfileobj(source, destination)
    executable.chmod(0o755)
    stockfish.append(str(executable))
subprocess.run(["lipo", "-create", *stockfish, "-output", str(root / "stockfish")], check=True)

for name, url, digest in [
    ("lc0", "https://github.com/LeelaChessZero/lc0/releases/download/v0.32.0/lc0-v0.32.0-macos_12.6.1", "2d276ad784fc0a9a00dc6e0a71d0340fb8805acf27a1874c769f3d8e7c60c81e"),
    ("weights.pb.gz", "https://storage.lczero.org/files/networks-contrib/t1-256x10-distilled-swa-2432500.pb.gz", "bc27a6cae8ad36f2b9a80a6ad9dabb0d6fda25b1e7f481a79bc359e14f563406"),
    ("maia3_simplified.onnx", "https://www.maiachess.com/maia3/maia3_simplified.onnx", "405bf76c15727dad8728b352c06a8f3c1b80fb2760e8d666b32485c63d75b856"),
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
