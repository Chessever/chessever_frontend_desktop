#!/usr/bin/env bash
set -euo pipefail

platform="${1:-desktop}"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "TELEGRAM_BOT_TOKEN is required"
  exit 1
fi

if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "TELEGRAM_CHAT_ID is required"
  exit 1
fi

version="$(awk '/^version:/ { print $2; exit }' pubspec.yaml 2>/dev/null || true)"
version="${version:-unknown}"
status="${CM_BUILD_STATUS:-${CM_BUILD_STEP_STATUS:-finished}}"
workflow="${CM_WORKFLOW_NAME:-${CM_WORKFLOW_ID:-unknown}}"
branch="${CM_BRANCH:-unknown}"
commit="${CM_COMMIT:-$(git rev-parse HEAD 2>/dev/null || true)}"
commit="${commit:-unknown}"
short_commit="${commit:0:8}"
build_id="${CM_BUILD_ID:-unknown}"

message=$(cat <<EOF
ChessEver desktop ${platform} release ${status}
Version: ${version}
Workflow: ${workflow}
Branch: ${branch}
Commit: ${short_commit}
Build: ${build_id}
EOF
)

jq -n \
  --arg chat_id "${TELEGRAM_CHAT_ID}" \
  --arg text "${message}" \
  '{
    chat_id: $chat_id,
    text: $text,
    link_preview_options: { is_disabled: true }
  }' |
  curl -fsS \
    -H 'Content-Type: application/json' \
    --data @- \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null

echo "Telegram notification sent"
