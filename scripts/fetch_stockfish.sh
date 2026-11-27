#!/usr/bin/env bash
# Downloads the official Stockfish binaries for macOS + Windows and lays
# them under assets/engine/ so the bundled-asset branch of
# `findStockfishBinary()` can find them.
#
# Run from the repo root:
#   bash scripts/fetch_stockfish.sh
#
# For dual macOS packaging, select the package flavor. Apple Silicon gets the
# thinned arm64 slice; Intel gets the whole universal file (see below):
#   MACOS_ENGINE_ARCH=arm64 bash scripts/fetch_stockfish.sh
#   MACOS_ENGINE_ARCH=x64   bash scripts/fetch_stockfish.sh
#
# Re-run any time you want to bump the engine version. The script is
# idempotent; existing files are overwritten.

set -euo pipefail

VERSION="${STOCKFISH_VERSION:-19}"
# arm64 | x64 — one package flavor per run (default arm64 for local dev).
MACOS_ENGINE_ARCH="${MACOS_ENGINE_ARCH:-arm64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$ROOT/assets/engine"

# Stockfish 19 ships one "universal" archive per OS. Each archive is pinned to
# the SHA-256 GitHub publishes for the sf_19 release; another STOCKFISH_VERSION
# must bring its own MAC_SHA256 / WIN_SHA256.
MAC_ASSET="stockfish-macos-universal.tar.gz"
MAC_BIN_NAME="stockfish-macos-universal"
WIN_ASSET="stockfish-windows-x86-64-universal.zip"
WIN_BIN_NAME="stockfish-windows-x86-64-universal.exe"
if [[ "$VERSION" == "19" ]]; then
  MAC_SHA256="${MAC_SHA256:-a1f0e3bcc5a6927a11fe6fc8e54a779754645f3c2bae2cf13420fd1957adaa77}"
  WIN_SHA256="${WIN_SHA256:-3c8bf1f9ea66a09350a40df4f632288285ac206d99f33ab5842c408fc30b48a7}"
fi
: "${MAC_SHA256:?set MAC_SHA256 for Stockfish $VERSION}"
: "${WIN_SHA256:?set WIN_SHA256 for Stockfish $VERSION}"

mkdir -p "$ASSET_DIR/macos" "$ASSET_DIR/windows"

scratch="$(mktemp -d)"
trap "rm -rf '$scratch'" EXIT

case "$MACOS_ENGINE_ARCH" in
  arm64|aarch64|silicon) MACOS_ENGINE_ARCH=arm64 ;;
  x64|x86_64|amd64|intel) MACOS_ENGINE_ARCH=x64 ;;
  *)
    echo "✗ MACOS_ENGINE_ARCH must be arm64 or x64 (got: $MACOS_ENGINE_ARCH)" >&2
    exit 1
    ;;
esac

download() {
  local asset="$1" digest="$2" out="$3"
  curl -sSfL --retry 3 \
    "https://github.com/official-stockfish/Stockfish/releases/download/sf_${VERSION}/${asset}" \
    -o "$out"
  local actual
  actual="$(shasum -a 256 "$out" 2>/dev/null || sha256sum "$out")"
  actual="${actual%% *}"
  if [[ "$actual" != "$digest" ]]; then
    echo "✗ $asset checksum mismatch (got $actual, want $digest)" >&2
    exit 1
  fi
}

echo "→ Downloading Stockfish ${VERSION} for macOS (${MACOS_ENGINE_ARCH} package)…"
mac_archive="$scratch/$MAC_ASSET"
download "$MAC_ASSET" "$MAC_SHA256" "$mac_archive"
tar -xzf "$mac_archive" -C "$scratch"
mac_bin="$scratch/stockfish/$MAC_BIN_NAME"
[[ -f "$mac_bin" ]] || {
  echo "✗ macOS binary not found inside archive (expected $MAC_BIN_NAME)" >&2
  exit 1
}

# The Apple Silicon package carries only the arm64 slice, which holds its own
# network. The Intel package must carry the whole universal file: since
# Stockfish 19 the x86_64 slice reads its network out of the arm64 slice of the
# same executable, and a thinned x86_64 slice exits at startup.
if [[ "$MACOS_ENGINE_ARCH" == "arm64" ]]; then
  if command -v lipo >/dev/null 2>&1; then
    lipo -thin arm64 "$mac_bin" -output "$ASSET_DIR/macos/stockfish"
  else
    echo "✗ lipo is required to thin the arm64 Stockfish slice" >&2
    exit 1
  fi
else
  cp "$mac_bin" "$ASSET_DIR/macos/stockfish"
fi
chmod +x "$ASSET_DIR/macos/stockfish"
echo "  ✓ assets/engine/macos/stockfish ($MACOS_ENGINE_ARCH package)"

# Windows — the universal x86-64 build picks the best code path for the CPU.
echo "→ Downloading Stockfish ${VERSION} for Windows (x86-64 universal)…"
win_archive="$scratch/$WIN_ASSET"
download "$WIN_ASSET" "$WIN_SHA256" "$win_archive"
unzip -qo "$win_archive" -d "$scratch"
win_bin="$scratch/stockfish/$WIN_BIN_NAME"
[[ -f "$win_bin" ]] || {
  echo "✗ Windows binary not found inside archive (expected $WIN_BIN_NAME)" >&2
  exit 1
}
cp "$win_bin" "$ASSET_DIR/windows/stockfish.exe"
echo "  ✓ assets/engine/windows/stockfish.exe"

# Verify the macOS engine matches the package flavor.
if command -v lipo >/dev/null 2>&1; then
  info="$(lipo -info "$ASSET_DIR/macos/stockfish" 2>/dev/null || true)"
  echo "  lipo: $info"
  case "$MACOS_ENGINE_ARCH" in
    arm64)
      echo "$info" | grep -E 'Non-fat file:.*arm64' >/dev/null || {
        echo "✗ expected an arm64-only Stockfish, got: $info" >&2
        exit 1
      }
      if echo "$info" | grep -q 'x86_64'; then
        echo "✗ arm64 package must not embed x86_64 Stockfish" >&2
        exit 1
      fi
      ;;
    x64)
      echo "$info" | grep -q 'x86_64' && echo "$info" | grep -q 'arm64' || {
        echo "✗ the Intel package needs the universal Stockfish (x86_64 reads its network from the arm64 slice), got: $info" >&2
        exit 1
      }
      ;;
  esac
fi

cat <<EOF

✓ Stockfish ${VERSION} bundled for macOS ${MACOS_ENGINE_ARCH} (+ Windows).

Next steps:

1. Build/publish with matching dart-define:
       --dart-define=MACOS_RELEASE_ARCH=${MACOS_ENGINE_ARCH}

2. The release workflows set MACOS_ENGINE_ARCH per package. Only the Intel
   DMG carries the universal engine, because its x86_64 slice needs it.
EOF
