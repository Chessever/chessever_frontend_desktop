#!/usr/bin/env bash
# Builds the experimental browser edition (app.chessever.com) into build/web.
#
#   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_ANON_KEY=sb_publishable_... \
#     scripts/build_web.sh
#
# The app is compiled to WebAssembly and drawn by the skwasm renderer; see
# docs/agents/web-build.md for why, what the browser edition leaves out, and how
# the output is hosted.
set -euo pipefail
cd "$(dirname "$0")/.."

# Everything compiled into a browser build is readable by every visitor
# (CLAUDE.md §2.12), so only values designed to be public are passed, and
# this list is all of them. GOOGLE_DESKTOP_CLIENT_ID / _SECRET are never
# read: browser sign-in uses Supabase's hosted OAuth, not the desktop
# loopback flow.
PUBLIC_DEFINES=(
  SUPABASE_URL
  SUPABASE_ANON_KEY
  SENTRY_FLUTTER
  CHESSEVER_CLOUDFLARE_API_BASE
  ANALYSIS_API_BASE
  GAMEBASE_PROXY_BASE
  BILLING_API_BASE
  BROADCAST_API_BASE
)

: "${SUPABASE_URL:?set SUPABASE_URL to the production project URL}"
: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY to the publishable key}"

case "$SUPABASE_ANON_KEY" in
  sb_secret_*)
    echo "SUPABASE_ANON_KEY is a secret key; the browser build takes the publishable key" >&2
    exit 1
    ;;
  ey*.*.*)
    claims="$(printf '%s' "$SUPABASE_ANON_KEY" | cut -d. -f2 | tr '_-' '/+')"
    while [ $(( ${#claims} % 4 )) -ne 0 ]; do claims="$claims="; done
    if printf '%s' "$claims" | base64 -d 2>/dev/null | grep -q '"role" *: *"service_role"'; then
      echo "SUPABASE_ANON_KEY is a service_role key; the browser build takes the anon key" >&2
      exit 1
    fi
    ;;
esac

# sqflite's browser backend runs sqlite3.wasm from sqlite3.dart's releases.
# The wasm must match the sqlite3 package version pinned in pubspec.lock.
SQLITE3_VERSION="3.3.3"
SQLITE3_WASM_SHA256="cfab48c6bbb718552ec19bc4f1365e19185311b72e4739cc19ef7333758304d3"

locked_sqlite3="$(awk '/^  sqlite3:$/ {found=1} found && /version:/ {gsub(/"/, "", $2); print $2; exit}' pubspec.lock)"
if [ "$locked_sqlite3" != "$SQLITE3_VERSION" ]; then
  echo "pubspec.lock has sqlite3 $locked_sqlite3, but this script fetches sqlite3.wasm $SQLITE3_VERSION." >&2
  echo "Update SQLITE3_VERSION and SQLITE3_WASM_SHA256 together." >&2
  exit 1
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

flutter pub get

# web/sqflite_sw.js and web/sqlite3.wasm are generated and git-ignored.
# `flutter run -d chrome --wasm -t lib/main_web.dart` needs them too, so
# running this script once also prepares a local debug run.
dart run sqflite_common_ffi_web:setup --force --no-sqlite3-wasm

if [ ! -f web/sqlite3.wasm ] || [ "$(sha256_of web/sqlite3.wasm)" != "$SQLITE3_WASM_SHA256" ]; then
  curl -fsSL -o web/sqlite3.wasm \
    "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_VERSION}/sqlite3.wasm"
fi
if [ "$(sha256_of web/sqlite3.wasm)" != "$SQLITE3_WASM_SHA256" ]; then
  echo "web/sqlite3.wasm does not match the pinned SHA-256" >&2
  exit 1
fi

defines=()
for key in "${PUBLIC_DEFINES[@]}"; do
  if [ -n "${!key:-}" ]; then
    defines+=("--dart-define=${key}=${!key}")
  fi
done

rm -rf build/web
# Icons are subset below instead: Flutter's own icon tree shaker reads the
# dart2js fallback, which is the small unsupported-browser app.
flutter build web \
  --release \
  --wasm \
  --target lib/main_web.dart \
  --no-web-resources-cdn \
  --no-tree-shake-icons \
  --base-href / \
  "${defines[@]}"

flutter_root="$(flutter --version --machine | sed -n 's/.*"flutterRoot": *"\([^"]*\)".*/\1/p')"
icons_kernel=build/web_icons/app.dill
rm -rf build/web_icons
mkdir -p build/web_icons
# Only the front end runs here (about half a minute); the kernel is what
# the icon subsetter reads.
"$flutter_root/bin/dart" compile wasm \
  --phases=cfe \
  --packages=.dart_tool/package_config.json \
  --extra-compiler-option="--platform=$flutter_root/bin/cache/flutter_web_sdk/kernel/dart2wasm_platform.dill" \
  -Ddart.vm.product=true \
  -o "$icons_kernel" \
  lib/main_web.dart
dart run scripts/subset_web_icon_fonts.dart build/web "$icons_kernel" "$flutter_root"
rm -rf build/web_icons

dart run scripts/finalize_web_build.dart build/web --preconnect "$SUPABASE_URL"
