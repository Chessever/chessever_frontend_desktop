#!/usr/bin/env bash
# Register GitHub Actions log masks for the encoded form of release dart-defines.
#
#   scripts/ci/mask_dart_defines.sh SUPABASE_URL SUPABASE_ANON_KEY ...
#
# This repo is public, so its Actions logs are too. GitHub masks a secret's
# literal value only, while Flutter hands every dart-define to Xcode, CMake and
# MSBuild base64-encoded ("KEY=VALUE" -> base64), and a failing native step can
# print that encoded list. Values are read from the environment variable of the
# same name; unset names are skipped.
set -euo pipefail

for name in "$@"; do
  value="${!name:-}"
  [ -n "$value" ] || continue
  printf '::add-mask::%s\n' "$(printf '%s=%s' "$name" "$value" | base64 | tr -d '\n')"
done
