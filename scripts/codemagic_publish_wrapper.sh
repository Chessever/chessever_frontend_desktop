#!/usr/bin/env bash
# Forced-command SSH wrapper for the codemagic-publisher user.
set -euo pipefail

ORIG="${SSH_ORIGINAL_COMMAND:-}"
# Retention: exactly one release per platform on the server. `desktop_updater`
# only ever targets the highest shortVersion and rollback is defined as a new
# forward build, so an older archive is dead weight the moment its successor is
# ingested. Do not raise this to keep "a spare" — see CLAUDE.md §2.11.
KEEP_LAST_N=1

case "$ORIG" in
  "rsync --server"*)
    exec $ORIG
    ;;
  "scp "*)
    exec $ORIG
    ;;
  "prepare")
    exec /usr/local/bin/codemagic-finalize prepare --keep-last-n "$KEEP_LAST_N"
    ;;
  "clear-legacy")
    exec /usr/local/bin/codemagic-finalize clear-legacy --keep-last-n "$KEEP_LAST_N"
    ;;
  "ingest "*)
    read -r _ platform archive version extra <<<"$ORIG"
    # Silicon continues bare macos; Intel is additive macos-x64.
    # macos-arm64 remains accepted for historical archives.
    case "$platform" in
      macos | macos-arm64 | macos-x64 | windows | linux) ;;
      *)
        echo "bad platform" >&2
        exit 2
        ;;
    esac
    if [ -n "${extra:-}" ]; then
      echo "too many ingest arguments" >&2
      exit 2
    fi
    case "$archive" in
      "" | *..* | */* | *\\*)
        echo "bad archive" >&2
        exit 2
        ;;
    esac
    case "$version" in
      "" | *..* | */* | *\\*)
        echo "bad version" >&2
        exit 2
        ;;
    esac
    exec /usr/local/bin/codemagic-finalize ingest \
      "$platform" "$archive" "$version" --keep-last-n "$KEEP_LAST_N"
    ;;
  "prune-downloads "*)
    read -r _ platform extra <<<"$ORIG"
    case "$platform" in
      macos | macos-arm64 | macos-x64 | windows | linux) ;;
      *)
        echo "bad platform" >&2
        exit 2
        ;;
    esac
    if [ -n "${extra:-}" ]; then
      echo "too many prune-downloads arguments" >&2
      exit 2
    fi
    exec /usr/local/bin/codemagic-finalize prune-downloads \
      "$platform" --keep-last-n "$KEEP_LAST_N"
    ;;
  *)
    echo "rejected: $ORIG" >&2
    exit 1
    ;;
esac
