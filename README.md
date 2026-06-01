# Chessever Desktop

Chessever is a Flutter desktop chess database client for macOS and Windows.
This repository is the desktop port of the Chessever app: the desktop shell
and platform integrations live under `lib/desktop/`, while the shared chess,
repository, provider, and service layers stay in the existing app structure.

The project is licensed under GPL-3.0. See `LICENSE`.

## Getting Started

### Prerequisites

- Flutter stable with Dart SDK support for this repo's `pubspec.yaml`.
- Xcode and CocoaPods for macOS desktop work.
- Visual Studio Build Tools for Windows desktop work.
- Access to the required service credentials for local development.

### Setup

```bash
git clone https://github.com/Chessever/chessever_frontend_desktop.git
cd chessever_frontend_desktop
flutter pub get
cp .env.example .env
flutter analyze
```

Fill `.env` with local development values. Do not commit `.env`, `.env.e2e`,
service account files, signing certificates, private keys, or generated local
tool configuration.

Required local keys for the desktop app are documented in `.env.example`.
Release builds pass the same values through `--dart-define` in Codemagic.

### Running Locally

```bash
flutter run -d macos
# or, on Windows:
flutter run -d windows
```

The bundled Stockfish 17.1 binaries are tracked at:

- `assets/engine/macos/stockfish`
- `assets/engine/windows/stockfish.exe`

Refresh them with `bash scripts/fetch_stockfish.sh` when bumping Stockfish.
The current binary SHA-256 values are recorded in
`lib/desktop/services/engine/desktop_engine_assets.md`.

## Security Before Public Release

Run both scanners before making release or visibility changes:

```bash
$(go env GOPATH)/bin/gitleaks detect --source . --log-opts="--all" --config .gitleaks.toml
trufflehog git file://"$PWD" --json --no-update --force-skip-binaries --results=verified,unknown --fail
```

Known exposed credentials from earlier history were removed with a history
rewrite before open-sourcing. Those credential values still need to remain
revoked or rotated in their upstream services; rewritten Git history does not
invalidate a copied secret.

See `SECURITY.md` for the release checklist, the secret-handling policy, and
how to report a vulnerability. The detailed credential-rotation evidence is
kept in the maintainers' private records, not in this public repository.

## Mobile E2E Tests

This repository includes a Patrol-based signed-in mobile E2E suite for route
coverage, live-data fetching, and chess-board engine assertions.

- Suite sources: `patrol_test/`
- Local smoke run: `./tool/patrol_smoke.sh`
- Local deep run: `./tool/patrol_deep.sh`
- Env template: `.env.e2e.example`

The suite runs the real app in a dedicated `E2E` mode, signs in with a real
test account, suppresses non-essential prompts, and exercises page roots,
search/filter flows, tournament/calendar/library/player routes, and board
interactions such as notation taps, move traversal, game swipes, and engine
line visibility.

## Generating Splash Screen

To generate or update the native splash screen for this project, run the following command in your
terminal:

```bash
flutter pub run flutter_native_splash:create
flutter gen-l10n
```

This command uses the `flutter_native_splash` package configuration defined in `pubspec.yaml`
to create splash screens for Android and iOS. And also generates localization utils.

```bash
dart run flutter_launcher_icons:generate
```bash
This command uses the `flutter_launcher_icons` package configuration defined in `pubspec.yaml`
to create app icons for Android and iOS. 


```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

This command will generate assets using `build_runner`
