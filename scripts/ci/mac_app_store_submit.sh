#!/usr/bin/env bash
# Upload the store edition and, by default, submit it for review. Approval
# never publishes it: MANUAL is the only supported App Store release type.
set -euo pipefail

if [ "${RELEASE_REF:-}" != refs/heads/main ]; then
  echo 'Mac App Store submissions require the desktop production branch.' >&2
  exit 1
fi
case "${SUBMIT_REVIEW:-true}:${REPLACE_PENDING_REVIEW:-false}" in
  true:true|true:false|false:false) ;;
  *) echo 'Invalid review options; replacing a review requires submission.' >&2; exit 1 ;;
esac

package="${STORE_OUTPUT:-build/mac-app-store}/ChessEver-Mac-App-Store.pkg"
test -s "$package"
if [ "${SUBMIT_REVIEW:-true}" = true ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$script_dir/app_store_review.py" --package "$package" \
    --platform MAC_OS --release-type MANUAL \
    --notes scripts/ci/mac_app_store_release_notes.txt \
    --replace-pending "${REPLACE_PENDING_REVIEW:-false}"
else
  app-store-connect publish --path "$package" --silent --disable-jwt-cache
fi
