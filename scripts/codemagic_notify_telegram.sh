#!/usr/bin/env bash
set -euo pipefail

platform="${1:-desktop}"
event="${2:-finished}"

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
success_marker="${CM_BUILD_DIR:-$PWD}/.codemagic_release_success"
case "$event" in
  started)
    status="started"
    ;;
  finished)
    if [ -f "$success_marker" ]; then
      status="succeeded"
    else
      status="failed"
    fi
    ;;
  *)
    status="$event"
    ;;
esac
workflow="${CM_WORKFLOW_NAME:-${CM_WORKFLOW_ID:-unknown}}"
branch="${CM_BRANCH:-unknown}"
commit="${CM_COMMIT:-$(git rev-parse HEAD 2>/dev/null || true)}"
commit="${commit:-unknown}"
short_commit="${commit:0:8}"
author="${CM_COMMIT_AUTHOR:-$(git log -1 --pretty=format:%an 2>/dev/null || true)}"
author="${author:-unknown}"
subject="$(git log -1 --pretty=format:%s 2>/dev/null || true)"
subject="${subject:-unknown}"
build_id="${CM_BUILD_ID:-unknown}"
build_url="${CM_BUILD_URL:-}"

case "$status" in
  started) emoji="🚀" ;;
  succeeded) emoji="✅" ;;
  failed) emoji="❌" ;;
  *) emoji="ℹ️" ;;
esac

message=$(cat <<EOF
${emoji} ChessEver desktop ${platform} release ${status}
Version: ${version}
Workflow: ${workflow}
Branch: ${branch}
Commit: ${short_commit} — ${subject}
Author: ${author}
Build: ${build_id}
EOF
)

if [ -n "$build_url" ]; then
  message="${message}
URL: ${build_url}"
fi

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
