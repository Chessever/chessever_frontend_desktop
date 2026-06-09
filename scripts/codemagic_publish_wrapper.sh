#!/usr/bin/env bash
# Forced-command SSH wrapper for the codemagic-publisher user.
set -euo pipefail

ORIG="${SSH_ORIGINAL_COMMAND:-}"

case "$ORIG" in
  "rsync --server"*)
    exec $ORIG
    ;;
  "scp "*)
    exec $ORIG
    ;;
  "prepare")
    exec /usr/local/bin/codemagic-finalize prepare
    ;;
  "clear-legacy")
    exec /usr/local/bin/codemagic-finalize clear-legacy
    ;;
  "ingest "*)
    read -r _ platform archive version extra <<<"$ORIG"
    case "$platform" in
      linux | macos | windows) ;;
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
    exec /usr/local/bin/codemagic-finalize ingest "$platform" "$archive" "$version"
    ;;
  "delete-previous "*)
    read -r _ platform archive extra <<<"$ORIG"
    case "$platform" in
      linux | macos | windows) ;;
      *)
        echo "bad platform" >&2
        exit 2
        ;;
    esac
    if [ -n "${extra:-}" ]; then
      echo "too many delete-previous arguments" >&2
      exit 2
    fi
    case "$archive" in
      "" | *..* | */* | *\\*)
        echo "bad archive" >&2
        exit 2
        ;;
    esac
    exec /usr/local/bin/codemagic-finalize delete-previous "$platform" "$archive"
    ;;
  *)
    echo "rejected: $ORIG" >&2
    exit 1
    ;;
esac
