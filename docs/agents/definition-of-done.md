<!-- Moved verbatim from AGENTS.md Part I (formerly CLAUDE.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

## 9. Definition of done (release-ready)

The Ralph loop's completion promise will only be true when **all** of these hold:

- [x] Mobile-only package call-sites are gated behind the desktop branch in `main.dart`. (Packages remain in `pubspec.yaml` but never load on the desktop runtime path.)
- [x] `flutter analyze` clean across `lib/desktop/`.
- [x] `flutter build macos --debug` succeeds and produces a runnable `.app`.
- [x] `flutter build macos --release` succeeds (151 MB release `.app`, launches and stays alive).
- [ ] `flutter build windows --debug` / `--release` — needs a Windows host (no CI; this repo intentionally has no `.github/workflows/`).
- [x] Cold-launch on macOS reaches the Board pane with no console errors. (`SQLite database created`, `Supabase init completed`.)
- [ ] Cold-launch on Windows — pending Windows verification.
- [x] Google OAuth loopback flow implemented (`GoogleOAuthLoopback`, `DesktopAuthService`); Apple uses Supabase-hosted OAuth through the desktop loopback callback on macOS and Windows. End-to-end browser flow not yet driven against configured provider credentials.
- [x] Engine evaluation: live UCI-driven `EnginePanel` parses depth / cp / mate / pv. Requires a Stockfish binary (Homebrew or PATH); auto-warms on startup, degrades gracefully when missing.
- [x] All eight panes render and respond to keyboard+mouse: Board (drag+tap+arrows+context menu), Tournaments (real Supabase data, double-click → load PGN), Library (folders + saved analyses + recent imports), Favorites (events + players cards), Players (search + table), Calendar (month list), Countrymen (focused empty state), Settings.
- [x] Window position/size persists across launches via `WindowStatePersistence` + `WindowListener`.
- [x] Drag-drop local chess files/folders → `LocalChessDropZone` routes them to the Library local browser, or to Board Editor's desktop import chooser when that pane is foreground, without implicit SQLite import.
- [x] Smoke-test checklist authored at `docs/desktop_smoke_test.md`.

Open work to flip the remaining boxes:

1. Run `flutter build macos --release` on a notarized signing identity.
2. Stand up a Windows host (or CI runner) for the Windows build + smoke test.
3. Bundle Stockfish binaries under `assets/engine/` and wire the asset → app-support copy step in `findStockfishBinary()`.
4. Drive the OAuth flow end-to-end against a `GOOGLE_DESKTOP_CLIENT_ID` issued for desktop.
5. Replace mobile-only packages per call-site (rather than the current "inert on desktop branch" approach) so `pubspec.yaml` stops carrying dead weight on desktop release builds.
