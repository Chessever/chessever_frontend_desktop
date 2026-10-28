#!/usr/bin/env bash
# Deploys build/web (from scripts/build_web.sh) to app.chessever.com as the
# Cloudflare Worker described in wrangler.web.jsonc. The custom domain route
# creates its DNS record and certificate on first deploy.
#
# Needs a wrangler login (or CLOUDFLARE_API_TOKEN) that can deploy Workers on
# the account owning the chessever.com zone, named by CLOUDFLARE_ACCOUNT_ID.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
: "${CLOUDFLARE_ACCOUNT_ID:?Set CLOUDFLARE_ACCOUNT_ID to the account that owns the chessever.com zone}"

if [[ ! -f build/web/main.dart.wasm ]]; then
  echo "build/web has no Wasm build; run scripts/build_web.sh first." >&2
  exit 1
fi
oversized="$(find build/web -type f -size +25M -not -path 'build/web/assets/assets/engine/*')"
if [[ -n "$oversized" ]]; then
  echo "Workers assets must be 25 MiB or smaller:" >&2
  echo "$oversized" >&2
  exit 1
fi

npx --yes wrangler@4 deploy -c wrangler.web.jsonc "$@"
