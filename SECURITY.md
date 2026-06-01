# Security Policy

## Reporting a Vulnerability

Please report security issues privately to the project maintainers before
opening a public issue. Include the affected component, reproduction steps, and
the impact you believe is possible.

Do not include live credentials, private keys, customer data, or production
tokens in GitHub issues, pull requests, screenshots, logs, or comments.

## Secret Handling

Secrets must live outside Git:

- Local development values belong in ignored `.env` or `.env.e2e` files.
- CI values belong in the `chessever-desktop-release` Codemagic environment
  group and must be marked secure when they are credentials.
- Signing certificates, private keys, App Store Connect private keys, service
  account JSON files, Firebase generated config, and APNs keys must not be
  committed.

The repository intentionally tracks `.env.example` and `.env.e2e.example` with
empty values only.

Desktop Google OAuth uses the installed-app loopback flow with PKCE. Do not
reuse a web/server OAuth client secret here; installed-app client values are
embedded in shipped binaries and cannot be treated as confidential server
secrets.

## Required Scans

Run these before changing repository visibility or publishing a release:

```bash
$(go env GOPATH)/bin/gitleaks detect --source . --log-opts="--all" --config .gitleaks.toml
trufflehog git file://"$PWD" --json --no-update --force-skip-binaries --results=verified,unknown --fail
```

For filesystem-only scans, skip bundled engine binaries if the scanner cannot
parse them:

```bash
tmpdir=$(mktemp -d /tmp/chessever-tracked-fs.XXXXXX)
git ls-files -z | while IFS= read -r -d '' file; do
  case "$file" in
    assets/engine/*) continue ;;
  esac
  mkdir -p "$tmpdir/$(dirname "$file")"
  cp "$file" "$tmpdir/$file"
done
trufflehog filesystem "$tmpdir" --json --no-update --force-skip-binaries --results=verified,unknown --fail
rm -rf "$tmpdir"
```

## Open-Source Release Gate

Before making the repository public:

- Confirm `git status --short --branch` is clean and aligned with `origin/main`.
- Confirm open pull request head branches still exist on GitHub.
- Confirm known historical credentials are revoked or rotated upstream.
- Confirm the maintainers' private credential-rotation records have evidence
  for every credential class marked pending. That evidence is kept outside
  this public repository.
- Confirm GitHub secret scanning is enabled after the repository becomes public
  or is available for the organization plan.
- Confirm Supabase security advisor has no `ERROR` findings on the linked
  project, and explicitly accept or remediate remaining WARN/INFO findings.
- Confirm the bundled Stockfish binaries were sourced from the official
  release and match the checksums in
  `lib/desktop/services/engine/desktop_engine_assets.md`.
- Confirm no server-only credential is passed to Flutter through
  `--dart-define`; compiled client values are extractable from shipped apps.
- Confirm `GAMEBASE_API_KEY` is configured only as a Supabase Edge Function
  secret for `gamebase-proxy`, not as a client build define.
