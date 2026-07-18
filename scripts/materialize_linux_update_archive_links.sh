#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <desktop_updater archive directory>" >&2
  exit 2
fi

ARCHIVE_DIR="$1"
[ -d "$ARCHIVE_DIR" ] || {
  echo "archive directory does not exist: $ARCHIVE_DIR" >&2
  exit 1
}

# desktop_updater:archive validates and hashes each Linux file symlink before
# this script runs. Materialize those aliases without changing their bytes, so
# the web payload remains hash-identical and clients can download DT_NEEDED
# names such as libonnxruntime.so.1 as ordinary files.
find "$ARCHIVE_DIR" -type l -print0 | while IFS= read -r -d '' link; do
  relative="${link#$ARCHIVE_DIR/}"
  materialized="$(mktemp "$link.materialized.XXXXXX")"
  echo "Materializing hashed Linux archive symlink $relative"
  cp -pL "$link" "$materialized"
  unlink "$link"
  mv "$materialized" "$link"
done
