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

# dartchess needs 64-bit integers, so the app only runs as Wasm; Flutter still
# emits a JavaScript fallback, which shows an unsupported-browser notice.
# Extra flags (e.g. --no-strip-wasm for readable stack traces) pass through.
flutter build web --wasm --release \
  -t lib/web/web_main.dart \
  --dart-define-from-file="$WEB_PUBLIC_CONFIG" \
  "$@"

# The desktop Stockfish binaries are bundled assets that never run in a
# browser, and each exceeds the 25 MiB per-file limit for Workers assets.
rm -rf build/web/assets/assets/engine

echo "Built build/web ($(du -sh build/web | cut -f1))"
