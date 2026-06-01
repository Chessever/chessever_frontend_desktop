#!/usr/bin/env bash
# Downloads the official Stockfish binaries for macOS + Windows and lays
# them under assets/engine/ so the bundled-asset branch of
# `findStockfishBinary()` can find them.
#
# Run from the repo root:
#   bash scripts/fetch_stockfish.sh
#
# Re-run any time you want to bump the engine version. The script is
# idempotent; existing files are overwritten.

set -euo pipefail

VERSION="${STOCKFISH_VERSION:-17.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$ROOT/assets/engine"

mkdir -p "$ASSET_DIR/macos" "$ASSET_DIR/windows"

scratch="$(mktemp -d)"
trap "rm -rf '$scratch'" EXIT

# macOS — Apple Silicon binary. Intel users on macOS 10.13+ can run the
# arm64 build under Rosetta; ship one binary.
echo "→ Downloading Stockfish ${VERSION} for macOS (arm64)…"
mac_archive="$scratch/stockfish-macos.tar"
curl -sSL --retry 3 \
  "https://github.com/official-stockfish/Stockfish/releases/download/sf_${VERSION}/stockfish-macos-m1-apple-silicon.tar" \
  -o "$mac_archive"
tar -xf "$mac_archive" -C "$scratch"
mac_bin="$(find "$scratch/stockfish" -type f -name 'stockfish-macos-m1-apple-silicon' | head -n 1)"
if [[ -z "$mac_bin" ]]; then
  echo "✗ macOS binary not found inside archive" >&2
  exit 1
fi
cp "$mac_bin" "$ASSET_DIR/macos/stockfish"
chmod +x "$ASSET_DIR/macos/stockfish"
echo "  ✓ assets/engine/macos/stockfish"

# Windows — generic AVX2 build covers most consumer CPUs from 2014 onward.
echo "→ Downloading Stockfish ${VERSION} for Windows (avx2)…"
win_archive="$scratch/stockfish-windows.zip"
curl -sSL --retry 3 \
  "https://github.com/official-stockfish/Stockfish/releases/download/sf_${VERSION}/stockfish-windows-x86-64-avx2.zip" \
  -o "$win_archive"
unzip -qo "$win_archive" -d "$scratch"
win_bin="$(find "$scratch/stockfish" -type f -name 'stockfish-windows-x86-64-avx2.exe' | head -n 1)"
if [[ -z "$win_bin" ]]; then
  echo "✗ Windows binary not found inside archive" >&2
  exit 1
fi
cp "$win_bin" "$ASSET_DIR/windows/stockfish.exe"
echo "  ✓ assets/engine/windows/stockfish.exe"

cat <<EOF

✓ Stockfish ${VERSION} bundled.

Next steps:

1. Add the new asset entries to pubspec.yaml under flutter.assets:
       - assets/engine/macos/stockfish
       - assets/engine/windows/stockfish.exe

2. Extend findStockfishBinary() step 1 to copy the bundled asset to
   getApplicationSupportDirectory() and chmod +x on macOS before
   returning the resolved path.
EOF
