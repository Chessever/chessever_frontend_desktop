#!/usr/bin/env bash
# Publishes the Linux desktop release, mirroring scripts/codemagic_publish_macos.sh:
#   1. validates the desktop_updater archive contract,
#   2. runs the release-env dart-define check against the built binary,
#   3. packages the bundle into a portable AppImage (GTK bundled),
#   4. uploads the archive + ingests it on the update server (auto-update channel),
#   5. publishes the AppImage to the stable website download URL.
#
# Linux has no Developer ID / notarization step — AppImages are distributed
# unsigned, the same way the Windows installer is. Everything else matches the
# macOS publish contract, including the server `prepare`/`ingest` commands.
#
# Additive: Linux-only. The macOS/Windows publish scripts are untouched and
# share no files with this one. The server `ingest linux ...` call is a no-op
# for the macOS/Windows channels.
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

require_command curl
require_command dart
require_command python3
require_command rsync
require_command ssh

# Must match codemagic_build_linux_release.sh and the app's compiled defines
# (lib/desktop/services/desktop_env.dart) so --verify-release-env passes.
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

# Runs the built Linux binary with --verify-release-env to confirm the
# dart-defines were compiled in. Mirrors run_release_env_check in the macOS
# script (which reads the value out of the .app bundle).
run_release_env_check() {
  local bundle_dir="$1"
  local executable_path="$bundle_dir/$PACKAGE_BINARY"
  [ -x "$executable_path" ] || die "missing app executable $executable_path"
  echo "Verifying release dart-defines in $bundle_dir"
  "$executable_path" "--verify-release-env=$EXPECTED_DART_DEFINE_KEYS" ||
    die "release dart-define verification failed for $bundle_dir"
}

# Byte-for-byte the same archive-contract validator used by the macOS and
# Windows publish scripts: every regular file on disk must be listed in
# hashes.json, and every listed path must be safe and present.
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

# Packages the staged Linux bundle into a portable AppImage. Uses linuxdeploy +
# the GTK plugin to bundle the GTK runtime so the AppImage runs on distros that
# don't ship GTK3. APPIMAGE_EXTRACT_AND_RUN avoids the FUSE requirement on CI.
build_appimage() {
  local bundle_dir="$1"
  local out_path="$2"
  local arch="x86_64"
  # appimagetool runs from $WORKDIR (subshells below), so a relative out_path
  # would resolve under $WORKDIR/dist (which doesn't exist) and mksquashfs dies
  # with "Could not create destination file". Resolve to an absolute path
  # against the repo root (current $PWD) and ensure the directory exists.
  case "$out_path" in
    /*) ;;
    *) out_path="$PWD/$out_path" ;;
  esac
  mkdir -p "$(dirname "$out_path")"
  local tools_dir="$WORKDIR/appimagetools"
  local appdir="$WORKDIR/AppDir"
  mkdir -p "$tools_dir"
  rm -rf "$appdir"
  mkdir -p "$appdir/usr/bin"
  export APPIMAGE_EXTRACT_AND_RUN=1

  curl -sSL --retry 3 -o "$tools_dir/linuxdeploy" \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${arch}.AppImage"
  curl -sSL --retry 3 -o "$tools_dir/linuxdeploy-plugin-gtk.sh" \
    "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"
  curl -sSL --retry 3 -o "$tools_dir/appimagetool" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${arch}.AppImage"
  chmod +x "$tools_dir/linuxdeploy" "$tools_dir/linuxdeploy-plugin-gtk.sh" "$tools_dir/appimagetool"
  export PATH="$tools_dir:$PATH"

  # Flutter's bundle is self-contained: the executable finds lib/ via an
  # $ORIGIN/lib rpath and data/ relative to itself. Copy the whole bundle into
  # usr/bin so those relative lookups still resolve inside the AppImage.
  cp -a "$bundle_dir/." "$appdir/usr/bin/"

  local desktop_file="$WORKDIR/com.chessever.desktop.desktop"
  cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Chessever
Exec=$PACKAGE_BINARY
Icon=chessever
Categories=Game;BoardGame;
Terminal=false
EOF

  # Reuse an in-repo PNG icon if one exists; otherwise synthesize a 1x1 so
  # linuxdeploy has something to install (the real icon ships inside the app).
  local icon_path="$WORKDIR/chessever.png"
  local icon_src=""
  for cand in \
    "$REPO_ROOT/assets/app_icon.png" \
    "$REPO_ROOT/linux/runner/resources/chessever.png" \
    "$REPO_ROOT/assets/images/app_icon.png" \
    "$REPO_ROOT/assets/images/icon.png" \
    "$REPO_ROOT/assets/logo.png"; do
    if [ -f "$cand" ]; then
      icon_src="$cand"
      break
    fi
  done
  if [ -n "$icon_src" ]; then
    cp "$icon_src" "$icon_path"
  else
    printf '%b' '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
      > "$icon_path"
  fi

  ( cd "$WORKDIR" && "$tools_dir/linuxdeploy" \
      --appdir "$appdir" \
      --executable "$appdir/usr/bin/$PACKAGE_BINARY" \
      --desktop-file "$desktop_file" \
      --icon-file "$icon_path" \
      --plugin gtk )

  ( cd "$WORKDIR" && OUTPUT="$out_path" "$tools_dir/appimagetool" "$appdir" "$out_path" )
  [ -f "$out_path" ] || die "AppImage was not produced at $out_path"
  chmod +x "$out_path"
  echo "Built AppImage $out_path"
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
ARCHIVE_NAME="${RELEASE_VERSION}-linux"
PACKAGE_NAME="$(awk '/^name:/{print $2; exit}' pubspec.yaml)"
[ -n "$PACKAGE_NAME" ] || die "unable to read pubspec package name"
# Linux executable name == CMake BINARY_NAME (linux/CMakeLists.txt), not the
# pubspec package name. Keep this in sync with set(BINARY_NAME ...).
PACKAGE_BINARY="Chessever"

for name in "${REQUIRED_DART_DEFINE_KEYS[@]}"; do
  require_env "$name"
done
EXPECTED_DART_DEFINE_KEYS="$(expected_dart_define_keys)"

BUNDLE="dist/${BUILD}/${PACKAGE_NAME}-${RELEASE_VERSION}-linux"
[ -d "$BUNDLE" ] || die "missing desktop_updater release bundle at $BUNDLE"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/chessever-linux-publish.XXXXXX")"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

run_release_env_check "$BUNDLE"

dart run desktop_updater:archive linux

ARCHIVE_DIR="dist/${BUILD}/${ARCHIVE_NAME}"

# Drop any symlinks desktop_updater leaves behind: the archive contract counts
# regular files only (mirrors the macOS publish step).
find "$ARCHIVE_DIR" -type l -print0 | while IFS= read -r -d '' link; do
  echo "Removing unhashed Linux archive symlink ${link#$ARCHIVE_DIR/}"
  rm -f "$link"
done
validate_desktop_updater_archive "$ARCHIVE_DIR"

echo "Prepared desktop_updater Linux archive $ARCHIVE_DIR"

APPIMAGE_PATH="dist/Chessever-${RELEASE_VERSION}-x86_64.AppImage"
build_appimage "$BUNDLE" "$APPIMAGE_PATH"

if [ "$SKIP_UPLOAD" -eq 1 ]; then
  echo "Skip upload set; not uploading or ingesting app archive."
  exit 0
fi

require_env CODEMAGIC_PUBLISHER_KEY
require_env CODEMAGIC_PUBLISH_REMOTE
KEY_PATH="$WORKDIR/codemagic_publisher_ed25519"
printf '%s\n' "$CODEMAGIC_PUBLISHER_KEY" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

# Publish target (user@host) comes from the Codemagic env group, never
# hardcoded — keeps the update-server address out of the public repo.
REMOTE="$CODEMAGIC_PUBLISH_REMOTE"
SSH_OPTS=(-i "$KEY_PATH" -o StrictHostKeyChecking=accept-new)
ssh "${SSH_OPTS[@]}" "$REMOTE" "prepare"
rsync -az --delete -e "ssh -i '$KEY_PATH' -o StrictHostKeyChecking=accept-new" \
  "$ARCHIVE_DIR/" "$REMOTE:/var/www/updates/desktop/archive/$ARCHIVE_NAME/"
ssh "${SSH_OPTS[@]}" "$REMOTE" "ingest linux $ARCHIVE_NAME $RELEASE_VERSION"

# Publish the latest AppImage to a stable URL for the website "Download for
# Linux" button. A versioned copy lives next to it for reference.
rsync -az -e "ssh -i '$KEY_PATH' -o StrictHostKeyChecking=accept-new" \
  "$APPIMAGE_PATH" "$REMOTE:/var/www/updates/desktop/downloads/Chessever-${RELEASE_VERSION}-x86_64.AppImage"
rsync -az -e "ssh -i '$KEY_PATH' -o StrictHostKeyChecking=accept-new" \
  "$APPIMAGE_PATH" "$REMOTE:/var/www/updates/desktop/downloads/Chessever.AppImage"

echo "Published Linux desktop_updater archive $RELEASE_VERSION"
echo "Published Linux AppImage: https://chessever.com/updates/desktop/downloads/Chessever.AppImage"
