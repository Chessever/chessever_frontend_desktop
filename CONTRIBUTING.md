# Contributing to Chessever Desktop

Thanks for your interest in Chessever Desktop — the macOS/Windows desktop
client for the Chessever chess database. This guide covers how to build, what
we expect in a change, and how to report problems responsibly.

## Project scope

This repository is the **desktop client**. It contains the Flutter desktop
shell (`lib/desktop/`) plus the shared chess, repository, provider, and
service layers reused from the mobile app. Backend services (Supabase
functions, database schema, billing, notifications) are operated separately
and are **not** required to build or run the client against your own backend.

No production backend credentials are included in this repository. Required
local keys are documented in `.env.example`; copy it to `.env` and fill in
your own development values.

## Getting set up

```bash
git clone https://github.com/Chessever/chessever_frontend_desktop.git
cd chessever_frontend_desktop
flutter pub get
cp .env.example .env      # fill in your own dev values
flutter analyze
```

- **macOS:** Xcode + CocoaPods.
- **Windows:** Visual Studio Build Tools (Desktop C++ workload).
- **Engine:** Stockfish 17.1 binaries are bundled under `assets/engine/`.
  See `lib/desktop/services/engine/desktop_engine_assets.md`.

Run locally with `flutter run -d macos` or `flutter run -d windows`.

## Before you open a pull request

- `flutter analyze` must be clean. This is the table-stakes signal.
- Add or update tests under `test/` for behavior you change.
- Keep desktop-only code under `lib/desktop/`. Do not put desktop-specific
  widgets in `lib/screens/`.
- A change that builds on one platform but breaks the other is not done.
  Prefer cross-platform packages; branch on `Platform.isMacOS` /
  `Platform.isWindows` only when behavior must diverge.
- Keep commits focused. Describe **what** changed and **why** in the body.

## Secrets and configuration

- Never commit `.env`, `.env.e2e`, signing certificates, private keys, App
  Store Connect keys, service-account JSON, or generated tool configuration.
- CI/release values live in the Codemagic environment group, not in Git.
- Run the scanners in `SECURITY.md` before any change that affects
  repository visibility or a release.

## Reporting security issues

Please **do not** open a public issue for a vulnerability. Follow the private
disclosure process in `SECURITY.md`.

## License

By contributing, you agree that your contributions are licensed under the
project's GPL-3.0 license (see `LICENSE`).
