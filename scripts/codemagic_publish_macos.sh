#!/usr/bin/env bash
set -euo pipefail

SKIP_UPLOAD=0
# arm64 | x64 — dual packages embed only one Stockfish slice each.
MACOS_RELEASE_ARCH="${MACOS_RELEASE_ARCH:-arm64}"
for arg in "$@"; do
  case "$arg" in
    --skip-upload)
      SKIP_UPLOAD=1
      ;;
    --arch=*)
      MACOS_RELEASE_ARCH="${arg#--arch=}"
      ;;
    --arch)
      shift_next=1
      ;;
    *)
      if [ "${shift_next:-0}" = "1" ]; then
        MACOS_RELEASE_ARCH="$arg"
        shift_next=0
      else
        echo "unknown argument: $arg" >&2
        exit 2
      fi
      ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

case "$MACOS_RELEASE_ARCH" in
  arm64|aarch64|silicon) MACOS_RELEASE_ARCH=arm64 ;;
  x64|x86_64|amd64|intel) MACOS_RELEASE_ARCH=x64 ;;
  *)
    die "MACOS_RELEASE_ARCH must be arm64 or x64 (got: $MACOS_RELEASE_ARCH)"
    ;;
esac

# Platform key in app-archive.json / archive dir / ingest CLI.
# Silicon continues the original `macos` slug; Intel is additive `macos-x64`.
if [ "$MACOS_RELEASE_ARCH" = "arm64" ]; then
  UPDATE_PLATFORM="macos"
  DMG_ARCH_LABEL=""
  STABLE_DMG_NAME="Chessever.dmg"
  EXPECTED_STOCKFISH_ARCH="arm64"
  FORBIDDEN_STOCKFISH_ARCH="x86_64"
else
  UPDATE_PLATFORM="macos-x64"
  DMG_ARCH_LABEL="intel"
  STABLE_DMG_NAME="Chessever-intel.dmg"
  EXPECTED_STOCKFISH_ARCH="x86_64"
  FORBIDDEN_STOCKFISH_ARCH="arm64"
fi

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "$name is required"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

require_command codesign
require_command dart
require_command ditto
require_command file
require_command lipo
require_command nm
require_command otool
require_command python3
require_command readlink
require_command xcrun

REQUIRED_DART_DEFINE_KEYS=(
  SUPABASE_URL
  SUPABASE_ANON_KEY
  GOOGLE_DESKTOP_CLIENT_ID
  GOOGLE_DESKTOP_CLIENT_SECRET
  SENTRY_FLUTTER
  CHESSEVER_CLOUDFLARE_API_BASE
)
OPTIONAL_DART_DEFINE_KEYS=(
  GOOGLE_WEB_CLIENT_ID
  BILLING_API_BASE
  GAMEBASE_PROXY_BASE
  TELEGRAM_FEEDBACK_BOT_TOKEN
  TELEGRAM_FEEDBACK_CHAT_ID
)

join_by_comma() {
  local IFS=,
  echo "$*"
}

expected_dart_define_keys() {
  local keys=("${REQUIRED_DART_DEFINE_KEYS[@]}")
  local name
  for name in "${OPTIONAL_DART_DEFINE_KEYS[@]}"; do
    if [ -n "${!name:-}" ]; then
      keys+=("$name")
    fi
  done
  join_by_comma "${keys[@]}"
}

run_release_env_check() {
  local app="$1"
  local executable_name
  local executable_path
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" ||
    die "unable to read CFBundleExecutable from $app"
  executable_path="$app/Contents/MacOS/$executable_name"
  [ -x "$executable_path" ] || die "missing app executable $executable_path"

  echo "Verifying release dart-defines in $app"
  "$executable_path" "--verify-release-env=$EXPECTED_DART_DEFINE_KEYS" ||
    die "release dart-define verification failed for $app"
}

validate_desktop_updater_archive() {
  local archive_dir="$1"
  local hashes_path="$archive_dir/hashes.json"
  [ -f "$hashes_path" ] || die "desktop_updater archive missing hashes.json at $archive_dir"

  python3 - "$archive_dir" <<'PY'
import json
import os
import sys

root = sys.argv[1]
hashes_path = os.path.join(root, "hashes.json")

with open(hashes_path, "r", encoding="utf-8") as f:
    entries = json.load(f)

listed = set()
missing = []
unsafe = []

for entry in entries:
    rel = entry.get("path") or entry.get("filePath")
    if not isinstance(rel, str) or not rel:
        unsafe.append(str(rel))
        continue
    parts = rel.split("/")
    if os.path.isabs(rel) or ".." in parts:
        unsafe.append(rel)
        continue
    listed.add(rel)
    if not os.path.isfile(os.path.join(root, *parts)):
        missing.append(rel)

extra = []
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
        if (
            rel == "hashes.json"
            or rel == ".DS_Store"
            or rel == ".desktop_updater_manifest.json"
            or rel.startswith("update/")
        ):
            continue
        if rel not in listed:
            extra.append(rel)

if unsafe or missing or extra:
    if unsafe:
        print("unsafe hashes.json paths:", unsafe, file=sys.stderr)
    if missing:
        print("hashes.json lists missing files:", missing, file=sys.stderr)
    if extra:
        print("archive contains unhashed regular files:", extra, file=sys.stderr)
    sys.exit(1)

print(f"Validated desktop_updater archive contract: {len(listed)} hashed files")
PY
}

validate_versioned_frameworks() {
  local frameworks_dir="$1"
  [ -d "$frameworks_dir" ] || die "missing macOS Frameworks directory at $frameworks_dir"

  local framework
  local current
  local current_target
  local plist
  local executable
  local version
  local version_plist
  local version_executable
  local valid_versions
  for framework in "$frameworks_dir"/*.framework; do
    [ -L "$framework" ] && die "framework root must not be a symlink: $framework"
    [ -d "$framework/Versions" ] || continue
    [ -L "$framework/Versions" ] && die "framework Versions directory must not be a symlink: $framework"
    current="$framework/Versions/Current"
    [ -L "$current" ] || die "missing Versions/Current symlink in $framework"
    current_target="$(readlink "$current")"
    case "$current_target" in
      ""|.|..|*/*)
        die "unsafe Versions/Current target '$current_target' in $framework"
        ;;
    esac
    [ -d "$framework/Versions/$current_target" ] ||
      die "broken Versions/Current symlink in $framework"
    [ ! -L "$framework/Versions/$current_target" ] ||
      die "Versions/Current must select a concrete directory in $framework"

    valid_versions=0
    for version in "$framework/Versions"/*; do
      [ -d "$version" ] || continue
      [ -L "$version" ] && continue
      version_plist="$version/Resources/Info.plist"
      [ -f "$version_plist" ] || continue
      version_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$version_plist" 2>/dev/null || true)"
      case "$version_executable" in
        ""|.|..|*/*) continue ;;
      esac
      [ -f "$version/$version_executable" ] || continue
      valid_versions=$((valid_versions + 1))
    done
    [ "$valid_versions" -eq 1 ] ||
      die "framework archive transport requires exactly one valid concrete version in $framework; found $valid_versions"

    plist="$framework/Versions/$current_target/Resources/Info.plist"
    [ -f "$plist" ] || die "missing framework Info.plist at $plist"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
    case "$executable" in
      ""|.|..|*/*)
        die "invalid CFBundleExecutable '$executable' in $plist"
        ;;
    esac
    [ -f "$framework/Versions/$current_target/$executable" ] ||
      die "Versions/Current does not select a version containing $executable in $framework"
    [ -L "$framework/$executable" ] ||
      die "missing framework executable symlink at $framework/$executable"
    [ "$(readlink "$framework/$executable")" = "Versions/Current/$executable" ] ||
      die "noncanonical framework executable symlink at $framework/$executable"

    # A framework's CFBundleExecutable can be a Mach-O dynamic library that
    # dyld loads rather than a process the OS launches. Recent Flutter builds
    # correctly emit App.framework/App as mode 0644, so requiring an execute
    # bit here rejects a valid signed framework. The concrete regular-file and
    # canonical-link checks above establish the archive layout; codesign
    # verification below establishes the executable payload's integrity.

    if [ -d "$framework/Versions/$current_target/Resources" ]; then
      [ -L "$framework/Resources" ] || die "missing Resources symlink in $framework"
      [ "$(readlink "$framework/Resources")" = "Versions/Current/Resources" ] ||
        die "noncanonical Resources symlink in $framework"
      [ -d "$framework/Resources" ] || die "broken Resources symlink in $framework"
    fi
  done
}

remove_transport_only_framework_links() {
  local archive_dir="$1"
  local frameworks_dir="$archive_dir/Frameworks"
  validate_versioned_frameworks "$frameworks_dir"

  local framework
  local current_target
  local executable
  local plist
  for framework in "$frameworks_dir"/*.framework; do
    [ -d "$framework/Versions" ] || continue
    current_target="$(readlink "$framework/Versions/Current")"
    plist="$framework/Versions/$current_target/Resources/Info.plist"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" ||
      die "unable to read CFBundleExecutable from $plist"

    echo "Removing reconstructible framework links from ${framework#$archive_dir/}"
    rm -f -- "$framework/$executable"
    if [ -L "$framework/Resources" ]; then
      rm -f -- "$framework/Resources"
    fi
    rm -f -- "$framework/Versions/Current"
  done

  local unexpected_links=()
  local link
  while IFS= read -r -d '' link; do
    unexpected_links+=("$link")
  done < <(find "$archive_dir" -type l -print0)
  if [ "${#unexpected_links[@]}" -ne 0 ]; then
    echo "error: updater archive contains unsupported symbolic links:" >&2
    for link in "${unexpected_links[@]}"; do
      echo "- ${link#$archive_dir/}" >&2
    done
    die "add an explicit transport or repair contract before publishing these links"
  fi
}

VERSION_RAW="$(awk '/^version:/{print $2; exit}' pubspec.yaml)"
[ -n "$VERSION_RAW" ] || die "unable to read version from pubspec.yaml"
VERSION="${VERSION_RAW%%+*}"
BUILD="${VERSION_RAW#*+}"
if [ "$BUILD" = "$VERSION_RAW" ]; then
  BUILD="${CM_BUILD_NUMBER:-}"
fi
[ -n "$VERSION" ] && [ -n "$BUILD" ] || die "pubspec.yaml version must include build metadata, got '$VERSION_RAW'"
RELEASE_VERSION="${VERSION}+${BUILD}"
ARCHIVE_NAME="${RELEASE_VERSION}-${UPDATE_PLATFORM}"
PACKAGE_NAME="$(awk '/^name:/{print $2; exit}' pubspec.yaml)"
[ -n "$PACKAGE_NAME" ] || die "unable to read pubspec package name"

echo "Publishing macOS arch=$MACOS_RELEASE_ARCH platform=$UPDATE_PLATFORM archive=$ARCHIVE_NAME"

for name in "${REQUIRED_DART_DEFINE_KEYS[@]}"; do
  require_env "$name"
done
EXPECTED_DART_DEFINE_KEYS="$(expected_dart_define_keys)"

APP="dist/${BUILD}/${PACKAGE_NAME}-${RELEASE_VERSION}-${UPDATE_PLATFORM}/${PACKAGE_NAME}.app"
[ -d "$APP" ] || die "missing desktop_updater release app at $APP"
validate_versioned_frameworks "$APP/Contents/Frameworks"

RESQLITE_FRAMEWORK="$APP/Contents/Frameworks/resqlite.framework"
RESQLITE_BIN="$RESQLITE_FRAMEWORK/resqlite"
[ -d "$RESQLITE_FRAMEWORK" ] || die "missing resqlite.framework from macOS app"
[ -L "$RESQLITE_BIN" ] || die "missing resqlite framework launcher at $RESQLITE_BIN"
[ -x "$RESQLITE_BIN" ] || die "resqlite framework launcher is not executable at $RESQLITE_BIN"
RESQLITE_FILE_INFO="$(file "$RESQLITE_BIN")" || die "unable to inspect $RESQLITE_BIN"
echo "$RESQLITE_FILE_INFO"
case "$RESQLITE_FILE_INFO" in
  *Mach-O*) ;;
  *) die "resqlite framework launcher is not a Mach-O binary" ;;
esac
lipo -info "$RESQLITE_BIN"
lipo "$RESQLITE_BIN" -verify_arch arm64 x86_64 ||
  die "resqlite framework must contain arm64 and x86_64 slices"
nm -gU "$RESQLITE_BIN" | awk '$NF == "_resqlite_open" { found = 1 } END { exit !found }' ||
  die "resqlite_open is not exported"
otool -L "$RESQLITE_BIN"

require_env APP_STORE_CONNECT_KEY_IDENTIFIER
require_env APP_STORE_CONNECT_ISSUER_ID
require_env APP_STORE_CONNECT_PRIVATE_KEY

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/chessever-macos-publish.XXXXXX")"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

IDENTITY="${CHESSEVER_DEV_ID_IDENTITY:-Developer ID Application: ChessEver LLC (N8J7TUZMYR)}"
sign_one() {
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
}

STOCKFISH="$APP/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/engine/macos/stockfish"
[ -x "$STOCKFISH" ] || die "missing Stockfish binary at $STOCKFISH"
STOCKFISH_INFO="$(lipo -info "$STOCKFISH" 2>/dev/null || file "$STOCKFISH")"
echo "Stockfish binary: $STOCKFISH_INFO"
echo "$STOCKFISH_INFO" | grep -E "$EXPECTED_STOCKFISH_ARCH" >/dev/null ||
  die "Stockfish must be $EXPECTED_STOCKFISH_ARCH-only for $UPDATE_PLATFORM (got: $STOCKFISH_INFO)"
if echo "$STOCKFISH_INFO" | grep -q "$FORBIDDEN_STOCKFISH_ARCH"; then
  die "Stockfish must not embed $FORBIDDEN_STOCKFISH_ARCH in the $UPDATE_PLATFORM package"
fi
if echo "$STOCKFISH_INFO" | grep -qi 'Architectures in the fat file'; then
  die "Stockfish must be a single-arch binary (no fat/universal engine) for $UPDATE_PLATFORM"
fi
sign_one "$STOCKFISH"
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -type d -name "*.framework" -prune -print |
    sort |
    while IFS= read -r framework; do
      sign_one "$framework"
    done
fi

/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements "$REPO_ROOT/macos/Runner/Release.entitlements" \
  --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
validate_versioned_frameworks "$APP/Contents/Frameworks"

ASC_KEY="$WORKDIR/AuthKey_${APP_STORE_CONNECT_KEY_IDENTIFIER}.p8"
printf '%s\n' "$APP_STORE_CONNECT_PRIVATE_KEY" > "$ASC_KEY"
chmod 600 "$ASC_KEY"
TMP_ZIP="$WORKDIR/chessever-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ZIP"
xcrun notarytool submit "$TMP_ZIP" --wait \
  --key "$ASC_KEY" \
  --key-id "$APP_STORE_CONNECT_KEY_IDENTIFIER" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
run_release_env_check "$APP"

dart run desktop_updater:archive "$UPDATE_PLATFORM"

ARCHIVE_DIR="dist/${BUILD}/${ARCHIVE_NAME}"

# The updater manifest transports regular files only. Strip only the canonical
# versioned-framework links that both native repair paths know how to recreate;
# an unknown link is a release blocker, never something to delete silently.
remove_transport_only_framework_links "$ARCHIVE_DIR"
validate_desktop_updater_archive "$ARCHIVE_DIR"

echo "Prepared desktop_updater macOS archive $ARCHIVE_DIR"

DMG_PATH="dist/Chessever-${RELEASE_VERSION}-${DMG_ARCH_LABEL}.dmg"
DMG_STAGING="$WORKDIR/dmg-staging"
mkdir -p "$DMG_STAGING"
ditto "$APP" "$DMG_STAGING/Chessever.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
  -volname "Chessever" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"
/usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --wait \
  --key "$ASC_KEY" \
  --key-id "$APP_STORE_CONNECT_KEY_IDENTIFIER" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
echo "Built DMG $DMG_PATH"

if [ "$SKIP_UPLOAD" -eq 1 ]; then
  echo "Skip upload set; not uploading or ingesting app archive."
  exit 0
fi

# Silicon continues Chessever.dmg + Chessever-<version>.dmg (original pattern).
# Intel is additive: Chessever-intel.dmg + Chessever-<version>-intel.dmg.
if [ -n "$DMG_ARCH_LABEL" ]; then
  VERSIONED_DMG_NAME="Chessever-${RELEASE_VERSION}-${DMG_ARCH_LABEL}.dmg"
else
  VERSIONED_DMG_NAME="Chessever-${RELEASE_VERSION}.dmg"
fi

require_env R2_ACCOUNT_ID
require_env R2_ACCESS_KEY_ID
require_env R2_SECRET_ACCESS_KEY
python3 "$REPO_ROOT/scripts/r2_publish_release.py" \
  --platform "$UPDATE_PLATFORM" \
  --release-version "$RELEASE_VERSION" \
  --archive-dir "$ARCHIVE_DIR" \
  --installer "$DMG_PATH" \
  --versioned-installer-name "$VERSIONED_DMG_NAME" \
  --stable-installer-name "$STABLE_DMG_NAME" \
  --scratch-dir "$WORKDIR/r2"

echo "Published macOS desktop_updater archive $RELEASE_VERSION ($UPDATE_PLATFORM)"
echo "Published macOS DMG: https://chessever.com/updates/desktop/downloads/${STABLE_DMG_NAME}"
