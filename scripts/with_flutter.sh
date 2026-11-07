#!/usr/bin/env bash
# Run a command with this repository's SDK, without changing the global PATH.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_version="$(cat "$repo_root/.flutter-version")"
flutter_sdk="${CHESSEVER_FLUTTER_SDK:-$HOME/.local/share/flutter-sdks/$flutter_version}"
if [[ ! -x "$flutter_sdk/bin/flutter" ]]; then
  echo "Flutter $flutter_version is missing at $flutter_sdk. See README.md." >&2
  exit 1
fi
export PATH="$flutter_sdk/bin:$PATH"
export FLUTTER_ROOT="$flutter_sdk"
if [[ $# -eq 0 ]]; then
  set -- flutter --version
fi
exec "$@"
