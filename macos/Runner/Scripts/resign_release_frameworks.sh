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
CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  IDENTITY="${CODE_SIGN_IDENTITY:-}"
fi

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  echo "warning: no Release code signing identity available; skipping embedded framework re-sign"
  exit 0
fi

ensure_symlink() {
  target="$1"
  link="$2"
  if [ -L "$link" ] && [ ! -e "$link" ]; then
    rm "$link"
  fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    return 0
  fi
  ln -s "$target" "$link"
}

framework_version_dir() {
  framework="$1"
  if [ -e "$framework/Versions/Current" ]; then
    printf '%s\n' "$framework/Versions/Current"
    return 0
  fi

  for version in "$framework"/Versions/*; do
    [ -d "$version" ] || continue
    printf '%s\n' "$version"
    return 0
  done

  return 1
}

framework_executable_name() {
  plist="$1"
  if [ -f "$plist" ]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true
  fi
}

repair_versioned_framework() {
  framework="$1"
  version="$(framework_version_dir "$framework")" || return 0
  version_base="$(basename "$version")"
  if [ "$version_base" != "Current" ]; then
    ensure_symlink "$version_base" "$framework/Versions/Current"
  fi

  current="$framework/Versions/Current"
  if [ ! -d "$current" ]; then
    return 0
  fi

  if [ -d "$current/Resources" ]; then
    ensure_symlink "Versions/Current/Resources" "$framework/Resources"
  fi

  executable="$(framework_executable_name "$current/Resources/Info.plist")"
  if [ -n "$executable" ] && [ -e "$current/$executable" ]; then
    ensure_symlink "Versions/Current/$executable" "$framework/$executable"
  fi
}

framework_sign_target() {
  framework="$1"
  if [ -d "$framework/Versions" ]; then
    repair_versioned_framework "$framework"
  fi
  printf '%s\n' "$framework"
}

sign_one() {
  path="$1"
  if [ ! -e "$path" ]; then
    return 0
  fi
  echo "Code signing embedded release payload: ${path#$APP_DIR/}"
  "$CODESIGN_BIN" --force --options runtime --timestamp --sign "$IDENTITY" "$path"
}

# Sign standalone executables before their containing framework is sealed.
STOCKFISH="$APP_DIR/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/engine/macos/stockfish"
if [ -x "$STOCKFISH" ]; then
  sign_one "$STOCKFISH"
fi

if [ -d "$FRAMEWORKS_DIR" ]; then
  for framework in "$FRAMEWORKS_DIR"/*.framework; do
    [ -e "$framework" ] || continue
    sign_one "$(framework_sign_target "$framework")"
  done
fi
