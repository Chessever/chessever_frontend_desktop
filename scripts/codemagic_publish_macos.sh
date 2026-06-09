#!/usr/bin/env bash
set -euo pipefail

SKIP_UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --skip-upload)
      SKIP_UPLOAD=1
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

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
require_command python3
require_command rsync
require_command ssh
require_command xcrun

REQUIRED_DART_DEFINE_KEYS=(
  SUPABASE_URL
  SUPABASE_ANON_KEY
  GOOGLE_DESKTOP_CLIENT_ID
  GOOGLE_DESKTOP_CLIENT_SECRET
  SENTRY_FLUTTER
)
OPTIONAL_DART_DEFINE_KEYS=(
  GOOGLE_WEB_CLIENT_ID
  BILLING_API_BASE
  GAMEBASE_PROXY_BASE
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

VERSION_RAW="$(awk '/^version:/{print $2; exit}' pubspec.yaml)"
[ -n "$VERSION_RAW" ] || die "unable to read version from pubspec.yaml"
VERSION="${VERSION_RAW%%+*}"
BUILD="${VERSION_RAW#*+}"
if [ "$BUILD" = "$VERSION_RAW" ]; then
  BUILD="${CM_BUILD_NUMBER:-}"
fi
[ -n "$VERSION" ] && [ -n "$BUILD" ] || die "pubspec.yaml version must include build metadata, got '$VERSION_RAW'"
RELEASE_VERSION="${VERSION}+${BUILD}"
ARCHIVE_NAME="${RELEASE_VERSION}-macos"
PACKAGE_NAME="$(awk '/^name:/{print $2; exit}' pubspec.yaml)"
[ -n "$PACKAGE_NAME" ] || die "unable to read pubspec package name"

for name in "${REQUIRED_DART_DEFINE_KEYS[@]}"; do
  require_env "$name"
done
EXPECTED_DART_DEFINE_KEYS="$(expected_dart_define_keys)"

APP="dist/${BUILD}/${PACKAGE_NAME}-${RELEASE_VERSION}-macos/${PACKAGE_NAME}.app"
[ -d "$APP" ] || die "missing desktop_updater release app at $APP"

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
[ -e "$STOCKFISH" ] && sign_one "$STOCKFISH"
sign_one "$APP/Contents/Frameworks/App.framework"

/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements "$REPO_ROOT/macos/Runner/Release.entitlements" \
  --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

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

dart run desktop_updater:archive macos

ARCHIVE_DIR="dist/${BUILD}/${ARCHIVE_NAME}"

# desktop_updater hashes regular files only. macOS framework launcher symlinks
# are stable across builds, so do not upload them as unhashed archive entries.
find "$ARCHIVE_DIR" -type l -print0 | while IFS= read -r -d '' link; do
  echo "Removing unhashed macOS archive symlink ${link#$ARCHIVE_DIR/}"
  rm -f "$link"
done
validate_desktop_updater_archive "$ARCHIVE_DIR"

echo "Prepared desktop_updater macOS archive $ARCHIVE_DIR"

DMG_PATH="dist/Chessever-${RELEASE_VERSION}.dmg"
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

require_env CODEMAGIC_PUBLISHER_KEY
KEY_PATH="$WORKDIR/codemagic_publisher_ed25519"
printf '%s\n' "$CODEMAGIC_PUBLISHER_KEY" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

REMOTE="codemagic-publisher@157.245.243.138"
SSH_OPTS=(-i "$KEY_PATH" -o StrictHostKeyChecking=accept-new)
ssh "${SSH_OPTS[@]}" "$REMOTE" "prepare"
rsync -az --delete -e "ssh -i '$KEY_PATH' -o StrictHostKeyChecking=accept-new" \
  "$ARCHIVE_DIR/" "$REMOTE:/var/www/updates/desktop/archive/$ARCHIVE_NAME/"
ssh "${SSH_OPTS[@]}" "$REMOTE" "ingest macos $ARCHIVE_NAME $RELEASE_VERSION"

# Publish the latest DMG to a stable URL for the website "Download for macOS"
# button. Versioned copies live next to it for reference.
rsync -az -e "ssh -i '$KEY_PATH' -o StrictHostKeyChecking=accept-new" \
  "$DMG_PATH" "$REMOTE:/var/www/updates/desktop/downloads/Chessever-${RELEASE_VERSION}.dmg"
rsync -az -e "ssh -i '$KEY_PATH' -o StrictHostKeyChecking=accept-new" \
  "$DMG_PATH" "$REMOTE:/var/www/updates/desktop/downloads/Chessever.dmg"
ssh "${SSH_OPTS[@]}" "$REMOTE" "delete-previous macos $ARCHIVE_NAME"

echo "Published macOS desktop_updater archive $RELEASE_VERSION"
echo "Published macOS DMG: https://chessever.com/updates/desktop/downloads/Chessever.dmg"
