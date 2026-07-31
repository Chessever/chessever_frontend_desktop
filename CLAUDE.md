# CLAUDE.md — chessever_frontend_desktop

This repo is the **desktop port** of the Chessever Flutter app, targeting **macOS and Windows**. The mission is to ship a desktop client that offers professional chess database capability in capability and UX while reusing the existing mobile codebase as the source of truth for domain logic, repositories, and providers.

This file is the orientation Claude reads on every Ralph-loop iteration. It is the contract for what "done" looks like and the rules of engagement while iterating.

---

## 1. Mission

- Turn the existing iOS/Android Chessever app into a **first-class native desktop application** for macOS and Windows.
- Match or exceed professional desktop-database ergonomics on the parts we already do well: live broadcast viewing, engine analysis, opening prep, game library, FEN/PGN import, study tools.
- Preserve the *visual identity* and *domain logic* of mobile. Replace only the things that are demonstrably wrong for keyboard+mouse on a 1440p display.

## 2. Non-negotiables

1. **Two platforms ship together.** A change that builds on macOS but breaks Windows (or vice versa) is not done. Use `Platform.isMacOS` / `Platform.isWindows` only when behavior must diverge; prefer cross-platform packages.
2. **No mobile-only package may remain in `pubspec.yaml`.** See §6 for the matrix. Replacements must run on both desktop platforms.
3. **No `dart:io` socket, FFI, or path call may assume mobile-only directories.** Use `path_provider` and check `Platform.isWindows` for path separators.
4. **Domain logic stays.** Repositories under `lib/repository/`, providers under `lib/providers/`, and feature view-models keep their public contracts. UI is what changes.
5. **Mobile shell stays buildable** during the transition (we do not delete mobile codepaths until the desktop shell is fully wired). Use platform branching in `main.dart` to pick the shell.
6. **Never claim completion that hasn't been verified.** A successful `flutter analyze` is not a successful build. A successful build is not a working app. Use the runners.
7. **Never run `flutter build` (macos/windows/ipa/apk/any target) to validate work.** Builds are slow, churn artifacts, and are reserved for the user / release flow. `flutter analyze` is the validation signal — if analyze is clean, the chunk is verified. Do not invoke `flutter build`, `flutter run`, or any compile-to-artifact command as a self-check. The user runs the app; you confirm with analyze.
8. **Updater pipeline is stable. Do not touch it unless explicitly requested.** The desktop updater already works end-to-end; do not modify its archive format, diff/staging/install flow, recovery markers, state machine, `DesktopUpdaterService`, or `third_party/desktop_updater` unless the user clearly asks for updater-pipeline work. Additive entry points such as native menu items may only call the existing public updater API and must not change updater behavior.
9. **Local chess cache writes must be single-writer.** `resqlite` serializes writes inside one `Database.open(...)` pool only; it does not coordinate multiple `Database.open(...)` handles or dedicated writer connections pointed at the same physical SQLite file. Library/Players code must not introduce ad hoc same-file resqlite opens for imports, deletes, purges, stat refreshes, source sync, or tree/cache rebuilds. Prefer the already-open app cache connection and route every mutation through the shared local chess write queue (`LocalChessDatabaseRepository._runLocalCacheWriteQueued` or the public helper that wraps it). If a dedicated connection is unavoidable, it must be documented, serialized by the same queue for its full write lifetime, and covered by a regression test that would fail on `ResqliteTransactionException: database is locked`.

## 3. UI direction

- **Primary UI library for desktop chrome: [forui](https://pub.dev/packages/forui).** Declared in `pubspec.yaml`; this is the chrome library — not optional. Use forui (NOT Material) for: sidebar items, dialogs, dropdowns, popovers, **tooltips**, command palette host, menus, sheets, command items, switches, sliders. If forui has a component for it, use forui.
  - **Never reach for `material.Tooltip` / `material.Dialog` / `material.PopupMenuButton` etc. in `lib/desktop/`.** Material's `Tooltip` was rewritten on top of `RawTooltip` in Flutter 3.41.9 and asserts on tab switches (`SingleTickerProviderStateMixin` ticker leak); forui sidesteps that and gives us native-feeling desktop chrome.
  - Reusable wrappers live under `lib/desktop/widgets/` (e.g. `desktop_tooltip.dart` wraps `FTooltip` with our defaults). Add new wrappers there rather than scattering raw `FTooltip`/`FDialog`/etc. across panes.
  - forui requires an `FTheme` ancestor. Either wrap the shell once or scope `FTheme` per-component when forui content sits inside a Material screen — both patterns are fine; don't mix `MaterialApp.theme` with forui defaults at the same level.
- **Existing widgets are the design vocabulary — for board / eval bar / PV list / score card / tournament list.** Those scale to desktop with layout changes, not a rewrite. *Only the chrome is forui — don't replace those widgets with forui equivalents.*
- **Game cards (Compact / List / Grid in `desktop_game_card.dart`) are exempt from the "reuse mobile" rule.** Redesign them freely for desktop — multi-column tile flows, denser footers, custom hover states, whatever reads best on a 1440 px pane. There is no "match mobile" contract on these.
- **Bespoke desktop buttons match the sidebar button vocabulary.** When a clickable control needs to feel native to the shell (toolbar pills, action buttons above the board, etc.) and a stock forui `FButton` reads as generic, copy the sidebar's look from `lib/desktop/shell/desktop_sidebar.dart` (`_SidebarItem` / `_SidebarHeaderButton`): rounded-8 pill, transparent→`kBlack3Color` hover fill, `kWhiteColor70`→`kWhiteColor` fg, `kPrimaryColor`-tinted "primary/selected" state (fill `0.10`/hover `0.16`, border `0.35`, accent fg), thin `kDividerColor` resting border, ~16–18px icon + 13px `w600` label, and the `SingleMotionBuilder`+`DesktopMotion` hover/press nudge with `CursorAware`. Reference impl: `lib/desktop/widgets/library/local_tree_action_button.dart`. (forui still owns dialogs/tooltips/menus/popovers per the first bullet — this is only for custom buttons.)
- Use the `frontend-design` skill when creating new desktop layouts — but constrain it to existing tokens (colors, fonts, radii) declared in `lib/theme/`.

## 4. Desktop UX rules (the part that actually changes from mobile)

The mobile app navigates through pushed routes. The desktop app does not push routes for primary navigation; it switches the **content pane** while the **shell** persists.

- **App shell:** persistent left sidebar (Tournaments, Library, Favorites, Players, Calendar, Countrymen, Settings), top window-chrome with platform menu bar, optional right inspector pane.
- **Multi-pane layouts:** the analysis screen shows board + move list + engine PVs + game header simultaneously; resizing is mouse-driven via splitters.
- **Keyboard-first:**
  - `←` / `→` step through moves; `↑` / `↓` jump to first/last; `Space` toggle autoplay.
  - `Cmd/Ctrl+K` open command palette (jump to tournament/player/feature).
  - `Cmd+Shift+F` on macOS / `Ctrl+Shift+F` on Windows opens global search from every pane, route, feature state, and nested Library/Players view. This is a shell-level invariant: new panes, route wrappers, focus scopes, shortcuts, text fields, and feature-level actions must not shadow or disable it.
  - `Cmd/Ctrl+O` open PGN; `Cmd/Ctrl+S` save current game; `Cmd/Ctrl+E` toggle engine; `Cmd/Ctrl+F` find in current view.
  - `F` flip board; `A` request analysis; `Esc` close active dialog/inspector.
- **Mouse:**
  - Hover tooltips on every move and eval-bar segment.
  - Right-click any move → context menu (annotate, branch, copy FEN, jump to engine line).
  - Drag-drop PGN files into the window → import.
  - Double-click on a tournament/game row → open in main pane.
- **Window:** resizable, min size 1024×720, remembers position and pane sizes between sessions.
- **No bottom nav, no hamburger drawer, no full-screen modal sheets** — those are mobile patterns.

## 5. Architecture (target)

```
lib/
  main.dart                       # entrypoint: branches on platform; on desktop, runs DesktopApp
  desktop/                        # NEW — desktop-specific code lives here
    desktop_app.dart              # MaterialApp/forui shell wrapper
    shell/                        # sidebar, top bar, command palette
    panes/                        # board_pane, analysis_pane, library_pane, etc.
    services/                     # window_manager, hotkeys, file_drop, menu_bar
    platform/                     # macos/windows-specific glue (notifications, single-instance)
  mobile/                         # (optional, future) wraps existing screens for mobile shell
  screens/                        # EXISTING — feature widgets reused on both shells
  repository/, providers/, services/   # EXISTING — unchanged domain layer
  theme/, widgets/, utils/        # EXISTING — shared
```

Desktop screens reuse the existing `screens/<feature>/` widgets. They wrap them in pane layouts; they do not reimplement them.

## 6. Package replacement matrix

| Package | Status | Replacement / Action |
|---|---|---|
| `stockfish` | ❌ mobile only | Bundle a native Stockfish binary per OS (`stockfish.exe` on Windows, Mach-O on macOS) and drive via `Process` + UCI over stdio. Wrap behind `StockfishEngine` interface; existing `StockfishSingleton` becomes a façade. |
| `onesignal_flutter` | ❌ mobile only | Drop. Desktop uses `local_notifier` for transient notifications. Push from server is out of scope for v1 desktop. |
| `flutter_native_splash` | ❌ mobile only | Drop. Use a Flutter-rendered splash widget gated by `StartupGate` (already exists). Native window stays hidden until first frame via `bitsdojo_window` / `window_manager`. |
| `clarity_flutter` | ❌ mobile only | Drop. Sentry already covers desktop. |
| `terminate_restart` | ❌ mobile only | Drop. Shorebird path doesn't apply to desktop; restart is user-driven. |
| `appsflyer_sdk` | ❌ mobile only | Drop. Attribution is a mobile install concern. |
| `app_tracking_transparency` | ❌ iOS only | Drop. |
| `receive_sharing_intent` | ❌ mobile only | Replace with `desktop_drop` for drag-drop file intake; OS file associations handle "Open With…". |
| `permission_handler` | ❌ no macOS | Drop on desktop. macOS permissions are entitlements declared in `macos/Runner/*.entitlements`. |
| `google_sign_in` | ❌ no Windows | Replace with OAuth web flow using `url_launcher` + a local loopback server (`HttpServer.bind('127.0.0.1', 0)`). Same pattern works on macOS. |
| `sign_in_with_apple` | ❌ no Windows | Keep gated to `Platform.isMacOS`; on Windows, hide the button. |
| `sqflite` | ❌ no Windows | Replace with `sqflite_common_ffi` and call `sqfliteFfiInit()` + set `databaseFactory = databaseFactoryFfi` on desktop. Existing `AppDatabase` keeps its API. |
| `purchases_flutter` | ✅ removed | Desktop billing is out of scope until Stripe is wired. Keep desktop gates open with the local subscription stub. |
| `amplitude_flutter` | ✅ removed | Unsupported on Windows. `AnalyticsService` remains package-free and keeps the local event API for mobile attribution forwarding. |
| `app_settings` | ❌ no Windows | Drop. Desktop has a Preferences window (forui). |
| `in_app_review` | ❌ no Windows | Drop. Desktop link to a feedback form. |
| `flutter_soloud` | ✅ desktop ok | Keep. |
| `firebase_core` + plugins | ⚠️ verify per plugin | Audit each `firebase_*` we depend on; remove unused. |
| `upgrader` | ⚠️ mobile-leaning | Replace with a Sparkle-style updater later; for now drop on desktop. |
| `marionette_flutter` (debug) | ⚠️ verify | Keep if it builds desktop, else gate to mobile. |
| `country_flags`, `flutter_country_flags`, `country_picker`, `country_code` | ✅ pure dart | Keep. |
| All other pure-dart packages | ✅ | Keep. |

**Add:** `forui`, `desktop_drop`, `window_manager` (or `bitsdojo_window`), `hotkey_manager`, `local_notifier`, `tray_manager` (optional), `sqflite_common_ffi`.

> **⚠️ Linux Stockfish engine is handled DIFFERENTLY from macOS/Windows.** The
> `flutter: assets:` list in `pubspec.yaml` is shared across all platforms, so
> any engine binary listed there is bundled into *every* desktop app. macOS +
> Windows engines (`assets/engine/macos/stockfish`, `assets/engine/windows/stockfish.exe`)
> are listed in pubspec normally. The Linux engine (`assets/engine/linux/stockfish`,
> ~78 MB) is **committed but intentionally NOT listed in pubspec** — listing it
> would bloat the mac/Windows downloads by 78 MB. Instead the Linux build script
> `scripts/codemagic_build_linux_release.sh` **injects** the
> `- assets/engine/linux/stockfish` line into pubspec at build time (idempotent
> awk insert after the Windows entry), so only the Linux bundle carries it.
> `uci_engine.dart` keeps the `Platform.isLinux` bundled-path branch (no-op on
> mac/Win). **Do not "fix" pubspec by adding the Linux line back** — that
> reintroduces the bloat.

## 7. Phases (the roadmap)

1. **Foundation** — write CLAUDE.md + AGENTS.md (this), bootstrap desktop runners, replace pubspec packages, wire `sqflite_common_ffi`, get `flutter run -d macos` past `main()`.
2. **Engine** — replace `stockfish` package with bundled-binary UCI driver behind existing `StockfishEngine` interface, both platforms.
3. **Auth** — implement OAuth loopback flow for Google and Supabase-hosted Apple OAuth on desktop; verify Supabase session persists.
4. **Shell** — desktop scaffold (sidebar + top menu + content pane + command palette) using forui. Wire existing tournament list as the first pane.
5. **Panes** — port board, analysis, library, favorites, calendar, players to multi-pane layouts. Add keyboard shortcuts and right-click menus.
6. **Services** — analytics over HTTP, local notifications, file-drop intake, single-instance, window state persistence.
7. **Polish & build** — `flutter build macos` + `flutter build windows` green, signed/notarized macOS .app, MSIX/installer Windows package, basic smoke test on both OSes.

We are at **Phase 1**. Do not skip ahead.

## 8. How to work on this repo

- Every iteration should leave the tree buildable on at least the current platform you're working on. If a package replacement breaks compilation for now, do it on a feature branch or land it together with its replacement.
- Read this file *and* `AGENTS.md` before you start. Read `lib/main.dart` for the current entry sequence.
- Never delete a mobile-only feature without first writing the desktop equivalent or putting it behind a `Platform` guard. Hot paths (auth, engine, persistence) get equivalents; cosmetic ones (in-app review prompts, ATT) get dropped.
- When introducing a new desktop file, place it under `lib/desktop/`. Don't pollute `lib/screens/` with desktop-only widgets.
- Tests live under `test/`. Add desktop-relevant tests next to the unit they cover.
- **Every commit that changes shipped code bumps `version:` in `pubspec.yaml`**, patch segment and build number together (`20.27.6+276` → `20.27.7+277`), with the new version at the end of the commit subject. The bump rides with the change, never as a follow-up `chore: bump`. Docs/test/CI-only commits are exempt. See `AGENTS.md` §2 — and note the phone repo now carries the same rule, so shared logic ported to both bumps both.
- `flutter analyze` clean is table stakes. `flutter run -d macos` and `flutter run -d windows` succeeding is the actual signal.

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

## 10. Anti-patterns (don't do these)

- ❌ Reimplementing the chess board, eval bar, or PV list because it "looks mobile-y." Resize and reuse. (Game cards in `desktop_game_card.dart` are NOT covered by this rule — redesign them however reads best on desktop.)
- ❌ Adding `if (kIsWeb)` branches. We are not shipping web.
- ❌ Stuffing desktop-only logic into existing screen files. Add a desktop wrapper instead.
- ❌ Deleting a feature because the desktop equivalent is hard. File a tracked TODO and move on.
- ❌ Output the loop's completion promise when it isn't true. The promise text is in the loop config; only emit it when §9 is fully satisfied.
- ❌ Run `flutter build <target>` (macos/windows/ios/android/web) as your own validation step. Builds belong to the user and the release flow. `flutter analyze` is the signal; stop there.
