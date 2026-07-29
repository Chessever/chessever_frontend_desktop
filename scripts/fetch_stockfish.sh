#!/usr/bin/env bash
# Downloads the official Stockfish binaries for macOS + Windows and lays
# them under assets/engine/ so the bundled-asset branch of
# `findStockfishBinary()` can find them.
#
# Run from the repo root:
#   bash scripts/fetch_stockfish.sh
#
# For dual macOS packaging, select exactly one engine arch so each package
# stays lean (no fat/universal Stockfish):
#   MACOS_ENGINE_ARCH=arm64 bash scripts/fetch_stockfish.sh
#   MACOS_ENGINE_ARCH=x64   bash scripts/fetch_stockfish.sh
#
# Re-run any time you want to bump the engine version. The script is
# idempotent; existing files are overwritten.

set -euo pipefail

VERSION="${STOCKFISH_VERSION:-17.1}"
# arm64 | x64 — one slice per package (default arm64 for local dev).
MACOS_ENGINE_ARCH="${MACOS_ENGINE_ARCH:-arm64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$ROOT/assets/engine"

mkdir -p "$ASSET_DIR/macos" "$ASSET_DIR/windows"

scratch="$(mktemp -d)"
trap "rm -rf '$scratch'" EXIT

case "$MACOS_ENGINE_ARCH" in
  arm64|aarch64|silicon)
    MACOS_ENGINE_ARCH=arm64
    MAC_ASSET="stockfish-macos-m1-apple-silicon.tar"
    MAC_BIN_GLOB='stockfish-macos-m1-apple-silicon'
    ;;
  x64|x86_64|amd64|intel)
    MACOS_ENGINE_ARCH=x64
    MAC_ASSET="stockfish-macos-x86-64-avx2.tar"
    MAC_BIN_GLOB='stockfish-macos-x86-64-avx2'
    ;;
  *)
    echo "✗ MACOS_ENGINE_ARCH must be arm64 or x64 (got: $MACOS_ENGINE_ARCH)" >&2
    exit 1
    ;;
esac

echo "→ Downloading Stockfish ${VERSION} for macOS (${MACOS_ENGINE_ARCH})…"
mac_archive="$scratch/stockfish-macos.tar"
curl -sSL --retry 3 \
  "https://github.com/official-stockfish/Stockfish/releases/download/sf_${VERSION}/${MAC_ASSET}" \
  -o "$mac_archive"
tar -xf "$mac_archive" -C "$scratch"
mac_bin="$(find "$scratch/stockfish" -type f -name "$MAC_BIN_GLOB" | head -n 1)"
if [[ -z "$mac_bin" ]]; then
  echo "✗ macOS binary not found inside archive (expected $MAC_BIN_GLOB)" >&2
  exit 1
fi
cp "$mac_bin" "$ASSET_DIR/macos/stockfish"
chmod +x "$ASSET_DIR/macos/stockfish"
echo "  ✓ assets/engine/macos/stockfish ($MACOS_ENGINE_ARCH)"

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

# Verify the macOS slice is not a fat binary and matches the requested arch.
if command -v lipo >/dev/null 2>&1; then
  info="$(lipo -info "$ASSET_DIR/macos/stockfish" 2>/dev/null || true)"
  echo "  lipo: $info"
  case "$MACOS_ENGINE_ARCH" in
    arm64)
      echo "$info" | grep -E 'architecture: arm64|Non-fat file:.*arm64' >/dev/null || {
        echo "✗ expected arm64-only Stockfish, got: $info" >&2
        exit 1
      }
      if echo "$info" | grep -q 'x86_64'; then
        echo "✗ arm64 package must not embed x86_64 Stockfish" >&2
        exit 1
      fi
      ;;
    x64)
      echo "$info" | grep -E 'architecture: x86_64|Non-fat file:.*x86_64' >/dev/null || {
        echo "✗ expected x86_64-only Stockfish, got: $info" >&2
        exit 1
      }
      if echo "$info" | grep -q 'arm64'; then
        echo "✗ intel package must not embed arm64 Stockfish" >&2
        exit 1
      fi
      ;;
  esac
fi

cat <<EOF

✓ Stockfish ${VERSION} bundled for macOS ${MACOS_ENGINE_ARCH} (+ Windows).

Next steps:

1. Build/publish with matching dart-define:
       --dart-define=MACOS_RELEASE_ARCH=${MACOS_ENGINE_ARCH}

2. Codemagic dual workflows set MACOS_ENGINE_ARCH per package so neither
   DMG carries both engine slices.
EOF
