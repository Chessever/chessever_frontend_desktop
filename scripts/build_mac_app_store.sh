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

STORE_OUTPUT="${STORE_OUTPUT:-$REPO_ROOT/build/mac-app-store}"
mkdir -p "$STORE_OUTPUT"
STORE_OUTPUT="$(cd "$STORE_OUTPUT" && pwd)"
python3 scripts/prepare_mac_app_store_engines.py "$STORE_OUTPUT/engines"

flutter build macos --release --config-only \
  --dart-define-from-file="$STORE_PUBLIC_CONFIG" \
  --dart-define=MAC_APP_STORE=true \
  --dart-define=CHESSEVER_SINGLE_INSTANCE_PORT=47684
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -derivedDataPath "$STORE_OUTPUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CHESSEVER_APP_STORE=YES \
  CODE_SIGN_ENTITLEMENTS=Runner/AppStore.entitlements \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

APP="$STORE_OUTPUT/ChessEver.app"
if [ -e "$APP" ]; then
  echo "Existing $APP must be moved aside before building another candidate." >&2
  exit 1
fi
ditto "$STORE_OUTPUT/DerivedData/Build/Products/Release/chessever.app" "$APP"
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
