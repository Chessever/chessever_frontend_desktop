#!/usr/bin/env bash
# Dedicated Mac App Store lane. Website updater/release scripts stay separate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
: "${STORE_PUBLIC_CONFIG:?Set STORE_PUBLIC_CONFIG to an allowlisted Dart define JSON file}"
: "${STORE_PROFILE:?Set STORE_PROFILE to the explicit Mac App Store provisioning profile}"
: "${STORE_KEYCHAIN:?Set STORE_KEYCHAIN to the signing keychain path}"
: "${STORE_APPLICATION_IDENTITY:?Set STORE_APPLICATION_IDENTITY to the Mac app signing identity SHA-1}"
: "${STORE_INSTALLER_IDENTITY:?Set STORE_INSTALLER_IDENTITY to the installer identity SHA-1}"

# Refuse a mismatched profile/configuration before spending time compiling.
python3 - <<'PY'
import json, os, plistlib, subprocess
from pathlib import Path
allowed = {'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'GOOGLE_DESKTOP_CLIENT_ID',
           'GOOGLE_DESKTOP_CLIENT_SECRET', 'SENTRY_FLUTTER',
           'CHESSEVER_CLOUDFLARE_API_BASE', 'ANALYSIS_API_BASE'}
config = json.loads(Path(os.environ['STORE_PUBLIC_CONFIG']).read_text())
if set(config) - allowed:
    raise SystemExit('Store build configuration contains a non-allowlisted key.')
profile = plistlib.loads(subprocess.check_output(
    ['security', 'cms', '-D', '-i', os.environ['STORE_PROFILE']]))
if (profile['Entitlements'].get('com.apple.application-identifier') !=
        'N8J7TUZMYR.com.chessever.desktop' or
        profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')):
    raise SystemExit('Expected the production ChessEver Mac App Store profile.')
# App Review requires the native Sign in with Apple sheet in this edition.
if 'Default' not in profile['Entitlements'].get('com.apple.developer.applesignin', []):
    raise SystemExit('The store profile must grant Sign in with Apple.')
PY

unlock_release_keychain() {
  python3 scripts/unlock_release_keychain.py \
    "$STORE_KEYCHAIN" "${STORE_KEYCHAIN_PASSWORD_FILE:-}"
}
# Fail before compiling instead of showing an unexpected macOS password prompt.
unlock_release_keychain

STORE_OUTPUT="${STORE_OUTPUT:-$REPO_ROOT/build/mac-app-store}"
mkdir -p "$STORE_OUTPUT"
STORE_OUTPUT="$(cd "$STORE_OUTPUT" && pwd)"
python3 scripts/prepare_mac_app_store_engines.py "$STORE_OUTPUT/engines"

# Use Flutter's standard universal release pipeline, including its matching
# OBJROOT/SYMROOT and generic macOS destination. Keep signing separate below.
export FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO
export FLUTTER_XCODE_CHESSEVER_APP_STORE=YES
export FLUTTER_XCODE_CODE_SIGN_ENTITLEMENTS=Runner/AppStore.entitlements
export FLUTTER_XCODE_ARCHS='arm64 x86_64'
export FLUTTER_XCODE_ONLY_ACTIVE_ARCH=NO
flutter build macos --release \
  --dart-define-from-file="$STORE_PUBLIC_CONFIG" \
  --dart-define=MAC_APP_STORE=true \
  --dart-define=CHESSEVER_SINGLE_INSTANCE_PORT=47684

APP="$STORE_OUTPUT/ChessEver.app"
if [ -e "$APP" ]; then
  echo "Existing $APP must be moved aside before building another candidate." >&2
  exit 1
fi
ditto "$REPO_ROOT/build/macos/Build/Products/Release/chessever.app" "$APP"
# An App Store package must run on both supported Mac architectures.
for binary in "$APP/Contents/MacOS/chessever" \
  "$APP/Contents/Frameworks/App.framework/App" \
  "$APP/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"; do
  for architecture in arm64 x86_64; do
    lipo "$binary" -verify_arch "$architecture"
  done
done
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Engines"
cp "$STORE_OUTPUT/engines/stockfish" "$APP/Contents/Helpers/stockfish"
cp "$STORE_OUTPUT/engines/lc0" "$APP/Contents/Helpers/lc0"
cp "$STORE_OUTPUT/engines/weights.pb.gz" "$APP/Contents/Resources/Engines/"
cp "$STORE_OUTPUT/engines/maia3_simplified.onnx" "$APP/Contents/Resources/Engines/"
cp "$STORE_OUTPUT/engines/Stockfish-LICENSE.txt" "$APP/Contents/Resources/Engines/"
cp LICENSE "$APP/Contents/Resources/Engines/ChessEver-and-Lc0-GPL-3.0.txt"
cp licenses/maia3-AGPL-3.0.txt "$APP/Contents/Resources/Engines/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Engines/Third-Party-Notices.md"
cp "$STORE_PROFILE" "$APP/Contents/embedded.provisionprofile"
# The source profile is private on disk. The embedded signed profile is public
# app metadata and must remain readable after the installer assigns root ownership.
chmod 644 "$APP/Contents/embedded.provisionprofile"
# The Flutter asset copy is never executable in the store lane. Keep all native
# executable code in signed code locations, and omit the unused Windows asset.
find "$APP/Contents/Frameworks/App.framework" -type d -path '*/flutter_assets/assets/engine' \
  -exec rm -rf -- {} +

security cms -D -i "$STORE_PROFILE" > "$STORE_OUTPUT/profile.plist"
python3 - "$STORE_OUTPUT" <<'PY'
from pathlib import Path
import plistlib, sys
output = Path(sys.argv[1])
profile = plistlib.loads((output / 'profile.plist').read_bytes())
entitlements = plistlib.loads(Path('macos/Runner/AppStore.entitlements').read_bytes())
for key in ('com.apple.application-identifier', 'com.apple.developer.team-identifier'):
    entitlements[key] = profile['Entitlements'][key]
(output / 'AppStore-signing.entitlements').write_bytes(plistlib.dumps(entitlements))
info_path = output / 'ChessEver.app/Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS'] = False
info_path.write_bytes(plistlib.dumps(info))
PY

# A long compile may have outlasted the keychain's normal auto-lock interval.
unlock_release_keychain
sign_code() {
  codesign --force --timestamp --options runtime --keychain "$STORE_KEYCHAIN" \
    --sign "$STORE_APPLICATION_IDENTITY" "$@"
}
# Sign nested native libraries first, followed by their containing frameworks.
while IFS= read -r -d '' code; do
  if file -b "$code" | rg -q 'Mach-O'; then sign_code "$code"; fi
done < <(find "$APP/Contents/Frameworks" -type f -print0)
while IFS= read -r -d '' framework; do sign_code "$framework"; done \
  < <(find "$APP/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
for helper in stockfish lc0; do
  sign_code --entitlements macos/Runner/AppStoreHelper.entitlements "$APP/Contents/Helpers/$helper"
done
sign_code --entitlements "$STORE_OUTPUT/AppStore-signing.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib, stat, sys
app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('LSApplicationCategoryType') != 'public.app-category.board-games':
    raise SystemExit('Missing Mac App Store category')
if (info.get('CFBundleIdentifier') != 'com.chessever.desktop' or
        info.get('ChessEverAppStoreBuild') != 'YES'):
    raise SystemExit('Package is not the production App Store edition')
for path in [app, *app.rglob('*')]:
    if path.is_symlink():
        continue
    mode = path.stat().st_mode
    if not mode & stat.S_IROTH or (path.is_dir() and not mode & stat.S_IXOTH):
        raise SystemExit(f'Installer payload is not publicly readable: {path}')
PY
productbuild --component "$APP" /Applications --sign "$STORE_INSTALLER_IDENTITY" \
  --keychain "$STORE_KEYCHAIN" "$STORE_OUTPUT/ChessEver-Mac-App-Store.pkg"
pkgutil --check-signature "$STORE_OUTPUT/ChessEver-Mac-App-Store.pkg"
echo "Prepared $STORE_OUTPUT/ChessEver-Mac-App-Store.pkg"
