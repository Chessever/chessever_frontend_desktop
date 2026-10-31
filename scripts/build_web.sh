#!/usr/bin/env bash
# Builds the browser app served at app.chessever.com (lib/web/web_main.dart)
# into build/web. Deploy it with scripts/deploy_web.sh.
#
# WEB_PUBLIC_CONFIG names a Dart define file (.json or .env). Everything in it
# is compiled into public JavaScript and Wasm, so only values designed to be
# public are accepted (CLAUDE.md §2.12).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
: "${WEB_PUBLIC_CONFIG:?Set WEB_PUBLIC_CONFIG to an allowlisted Dart define file (.json or .env)}"

python3 - <<'PY'
import json, os
from pathlib import Path
allowed = {'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'GAMEBASE_PROXY_BASE',
           'CHESSEVER_CLOUDFLARE_API_BASE', 'ANALYSIS_API_BASE',
           'BROADCAST_API_BASE', 'BILLING_API_BASE'}
path = Path(os.environ['WEB_PUBLIC_CONFIG'])
text = path.read_text()
if path.suffix == '.json':
    keys = set(json.loads(text))
else:
    keys = {line.split('=', 1)[0].strip() for line in text.splitlines()
            if '=' in line and not line.lstrip().startswith('#')}
extra = sorted(keys - allowed)
if extra:
    raise SystemExit(f'Web build configuration has non-public keys: {extra}')
missing = sorted({'SUPABASE_URL', 'SUPABASE_ANON_KEY'} - keys)
if missing:
    raise SystemExit(f'Web build configuration is missing: {missing}')
PY

# dartchess needs 64-bit integers, so the app only runs as Wasm. Flutter still
# emits a JavaScript build; web/flutter_bootstrap.js never selects it and shows
# an HTML unsupported-browser notice instead.
# Extra flags (e.g. --no-strip-wasm for readable stack traces) pass through.
flutter build web --wasm --release \
  -t lib/web/web_main.dart \
  --dart-define-from-file="$WEB_PUBLIC_CONFIG" \
  "$@"

# The desktop Stockfish binaries are bundled assets that never run in a
# browser, and each exceeds the 25 MiB per-file limit for Workers assets.
rm -rf build/web/assets/assets/engine

# Fonts. The web engine downloads every font in FontManifest.json before it
# draws the first frame, so each listed file is startup cost.
#  1. forui ships nine static Inter weights and the web theme uses Inter
#     (lib/desktop/desktop_app.dart). Nothing in lib/, chessground or forui
#     asks for w100-w300; a request for one would resolve to the nearest
#     weight kept. Dropping Thin, ExtraLight and Light saves ~0.9 MB.
#  2. index.html gets a preload per remaining font. The engine only fetches
#     them after main.dart.wasm has downloaded and compiled; preloaded, they
#     download alongside it. The engine fetches 'assets/<asset>' with a plain
#     fetch(), which an `as="fetch" crossorigin` preload matches exactly.
python3 - <<'PY'
import json
from pathlib import Path
from urllib.parse import quote

web = Path('build/web')
manifest_path = web / 'assets' / 'FontManifest.json'
manifest = json.loads(manifest_path.read_text())

unused_inter = {f'Inter-{w}.ttf' for w in ('Thin', 'ExtraLight', 'Light')}
dropped = []
for family in manifest:
    if family['family'] != 'packages/forui/Inter':
        continue
    kept = []
    for font in family['fonts']:
        if Path(font['asset']).name in unused_inter:
            dropped.append(font['asset'])
        else:
            kept.append(font)
    family['fonts'] = kept
if len(dropped) != len(unused_inter):
    raise SystemExit(f'Expected to drop {sorted(unused_inter)} from forui Inter, '
                     f'dropped {dropped}; check FontManifest.json')
manifest_path.write_text(json.dumps(manifest, separators=(',', ':')))
for asset in dropped:
    (web / 'assets' / asset).unlink(missing_ok=True)

# Uri.encodeFull keeps these characters, so the URLs match the engine's.
links = []
for family in manifest:
    for font in family['fonts']:
        href = 'assets/' + quote(font['asset'], safe="/:@!$&'()*+,;=-._~")
        links.append(f'<link rel="preload" href="{href}" as="fetch" '
                     f'crossorigin fetchpriority="low">')
marker = '<!-- flutter-font-preloads -->'
index = web / 'index.html'
html = index.read_text()
if html.count(marker) != 1:
    raise SystemExit(f'{index} must contain {marker} exactly once')
index.write_text(html.replace(marker, '\n  '.join(links)))
print(f'Fonts: dropped {len(dropped)} unused Inter weights, preloading {len(links)}')
PY

echo "Built build/web ($(du -sh build/web | cut -f1))"
