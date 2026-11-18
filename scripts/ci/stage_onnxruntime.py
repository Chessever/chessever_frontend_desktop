#!/usr/bin/env python3
"""Stage the pinned Flutter plugin's native ONNX Runtime for release builds."""

import argparse
import hashlib
import io
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile


VERSION = "1.22.0"
PACKAGE = "microsoft.ml.onnxruntime"
PACKAGE_URL = f"https://api.nuget.org/v3-flatcontainer/{PACKAGE}/{VERSION}/{PACKAGE}.{VERSION}.nupkg"
PACKAGE_SHA256 = "d571e63a2329baacb713f441e65ad75284de354db6e1ac435fe4bebbb417986a"


def stage(platform: str) -> None:
    # The plugin normally fetches the same runtime from GitHub releases. Its
    # CMake scripts reuse this directory when the SDK headers already exist.
    build = Path("build") / platform / "x64"
    if platform == "linux":
        build /= "release"
        rid = "linux-x64"
        libraries = {
            "libonnxruntime.so": f"libonnxruntime.so.{VERSION}",
            "libonnxruntime_providers_shared.so": "libonnxruntime_providers_shared.so",
        }
    else:
        rid = "win-x64"
        libraries = {"onnxruntime.dll": "onnxruntime.dll", "onnxruntime.lib": "onnxruntime.lib"}

    with urlopen(PACKAGE_URL, timeout=60) as response:
        payload = response.read()
    if hashlib.sha256(payload).hexdigest() != PACKAGE_SHA256:
        raise SystemExit(f"Microsoft ONNX Runtime {VERSION} package SHA-256 mismatch")

    sdk = build / "plugins/flutter_onnxruntime/onnxruntime" / f"onnxruntime-{rid}-{VERSION}"
    headers = sdk / "include"
    lib = sdk / "lib"
    headers.mkdir(parents=True, exist_ok=True)
    lib.mkdir(parents=True, exist_ok=True)
    with ZipFile(io.BytesIO(payload)) as package:
        for member, name in libraries.items():
            (lib / name).write_bytes(package.read(f"runtimes/{rid}/native/{member}"))
        for member in package.namelist():
            if member.startswith("build/native/include/") and member.endswith(".h"):
                (headers / Path(member).name).write_bytes(package.read(member))

    if platform == "linux":
        # The linker uses .so and the loader uses the library's .so.1 SONAME.
        for name in ("libonnxruntime.so", "libonnxruntime.so.1"):
            link = lib / name
            link.unlink(missing_ok=True)
            link.symlink_to(libraries["libonnxruntime.so"])
    print(f"Staged Microsoft ONNX Runtime {VERSION} for {rid} in {sdk}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("windows", "linux"))
    stage(parser.parse_args().platform)
