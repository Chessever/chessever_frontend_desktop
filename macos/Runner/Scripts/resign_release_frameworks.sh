#!/bin/sh
set -eu

# Flutter's macOS release runner launches the app directly from Xcode's
# build product. On recent macOS versions a hardened Developer ID app can be
# killed by dyld if embedded frameworks are left without hardened-runtime
# signatures, even when the outer app verifies. Sign them before Xcode seals
# the final app bundle.
if [ "${CONFIGURATION:-}" != "Release" ]; then
  exit 0
fi

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  exit 0
fi

APP_DIR="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  IDENTITY="${CODE_SIGN_IDENTITY:-}"
fi

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  echo "warning: no Release code signing identity available; skipping embedded framework re-sign"
  exit 0
fi

sign_one() {
  path="$1"
  if [ ! -e "$path" ]; then
    return 0
  fi
  echo "Code signing embedded release payload: ${path#$APP_DIR/}"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$path"
}

# Sign standalone executables before their containing framework is sealed.
STOCKFISH="$APP_DIR/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/engine/macos/stockfish"
if [ -x "$STOCKFISH" ]; then
  sign_one "$STOCKFISH"
fi

if [ -d "$FRAMEWORKS_DIR" ]; then
  for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -e "$framework" ] || continue
    sign_one "$framework"
  done
fi
