# AGENTS.md — chessever_frontend_desktop

> **Single source of truth for every coding agent.** `CLAUDE.md` is just
> `@AGENTS.md` (Claude Code import); Codex, Cursor, Kiro and opencode read this
> file directly. It merges the former `CLAUDE.md` (**Part I — project
> contract**, the *what* and *why*) and the former `AGENTS.md` (**Part II —
> working agreements**, the *how*). Both keep their original section numbers,
> so a citation `CLAUDE.md §N` in code comments, scripts or tests means
> **Part I §N**, and `AGENTS.md §N` means **Part II §N**. Long reference
> sections live in `docs/agents/`, stubbed below under their original headings
> with the path — read the file before you work in that area; it is just as
> binding.

> **This app also ships as a web app at app.chessever.com.** The same
> `lib/desktop/` shell runs in the browser as Wasm (`lib/web/web_main.dart`),
> and the goal is full feature parity with the desktop app. Every feature and
> fix is adapted to the browser in the same change, through browser
> implementations of the platform mechanism, never by hiding it behind
> `kIsWeb`. Rules, deploy steps and gap tracking: "Web port parity and
> synchronized updates" in Part I, and `docs/web_build_feature_parity.md`.

## Fast checks — run these first

| What | Fast (while iterating) | Reference / gate |
|---|---|---|
| Analyze | `dartr analyze <paths>` when `dartr` is on PATH | `flutter analyze` — once before you finish; it is the validation signal (Part II §8) |
| Format | `dartr format <paths>` | `dart format <paths>` |
| Fix preview | `dartr fix --dry-run` | `dart fix --dry-run` |
| Tests | `flutter test test/desktop/<file>_test.dart` (narrowest file that covers the change) | `flutter test` once at the end |

- dartr (`brew install orestesgaolin/tap/dartr`) is a preview Rust port of the
  Dart 3.13.3 analyzer and we run Dart 3.14 beta, so it is a fast first pass
  only. Run `flutter analyze` once before finishing; if they disagree,
  `flutter analyze` wins. `analysis_options.yaml` has no analyzer `plugins:`
  (plain `flutter_lints`), so there are no plugin-only lints dartr would miss.
- Run the narrowest tests first; the full suite once at the end.
- None of this relaxes the build rule: never `flutter build` / `flutter run`
  to self-verify (Part I §2.7, Part II §9).

---

# Part I — Project contract (formerly `CLAUDE.md`; cited as `CLAUDE.md §N`)

This repo is the **desktop port** of the Chessever Flutter app, targeting **macOS and Windows**. The mission is to ship a desktop client that offers professional chess database capability in capability and UX while reusing the existing mobile codebase as the source of truth for domain logic, repositories, and providers.

This file is the orientation Claude reads on every Ralph-loop iteration. It is the contract for what "done" looks like and the rules of engagement while iterating.

---

## 1. Mission

- Turn the existing iOS/Android Chessever app into a **first-class native desktop application** for macOS and Windows.
- Match or exceed professional desktop-database ergonomics on the parts we already do well: live broadcast viewing, engine analysis, opening prep, game library, FEN/PGN import, study tools.
- Preserve the *visual identity* and *domain logic* of mobile. Replace only the things that are demonstrably wrong for keyboard+mouse on a 1440p display.
- Keep the browser port at **app.chessever.com** updated together with the
  desktop app. Full desktop feature parity is the target; shared features and
  fixes must reach both distributions.

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
10. **Apple Silicon macOS release naming is frozen. Intel is additive only.** Silicon has shipped under the same identifiers since the first desktop release and they must never change:
    - updater platform key / archive dir slug / `ingest` arg: **`macos`** (bare — never `macos-arm64`, never `macos-silicon`)
    - stable website DMG: **`Chessever.dmg`**
    - versioned DMG: **`Chessever-<version>.dmg`** (no arch label)

    Intel, added later, is a **parallel additive** set that must not perturb any of the above: platform key `macos-x64`, DMG label `intel`, stable `Chessever-intel.dmg`, versioned `Chessever-<version>-intel.dmg`. The branch that decides this lives in `scripts/codemagic_publish_macos.sh` (`UPDATE_PLATFORM` / `DMG_ARCH_LABEL` / `STABLE_DMG_NAME`) and is correct today — do not "normalize", "symmetrize", or arch-suffix the Silicon side to make the two branches look alike. Renaming Silicon strands every existing installed client (they poll `platform: macos`) and breaks the website download link.

    Corollary for consumers: anything linking a macOS build (chessever.com `#download`, docs, release notes) must point at `Chessever.dmg` for Silicon. **`Chessever-arm64.dmg` is not a download to link to**: the release flow writes it only as a copy of `Chessever.dmg` for the stranded builds described below. When adding a new macOS variant, add new names beside the frozen ones; never repoint or rename the existing ones.

    **Builds 264/265 were stranded by a Silicon rename (Jul 29–30) and two compensations keep them alive** — the release service's additive `macos-arm64` mirror and `downloads/Chessever-arm64.dmg`. They **must not be "cleaned up"** until those installs have drained; read `docs/agents/macos-arm64-stranded-builds.md` before touching either, or the release service / R2 publish script.

    `test/desktop/macos_release_arch_test.dart` pins the frozen Silicon strings so this cannot recur silently.
11. **Exactly one release per platform lives in release storage.** `KEEP_LAST_N=1` in `scripts/codemagic_publish_wrapper.sh` applies this policy to the legacy release server, and `KEEP_RELEASES_PER_PLATFORM=1` in `scripts/r2_publish_release.py` applies it to R2 after a new release and both updater manifests have been uploaded successfully. One release per platform means one `archive/<version+build-platform>/` directory, one `app-archive.json` item, and one versioned download per platform — plus the stable aliases (`Chessever.dmg`, `Chessever-intel.dmg`, `Chessever-Setup.exe`, `Chessever.deb`), which are overwritten in place and never counted as history.

    This is safe because `desktop_updater` always targets the highest `shortVersion` and rollback is defined as a new forward build (`docs/AUTO_UPDATER_SETUP.md`), so a superseded archive is never fetched again. Do not raise the value to "keep a spare" — four platforms × ~1.3 GB of archives per retained release is what fills the droplet. The one real cost: a client mid-download of the previous archive when the next release is ingested loses its staged diff and re-checks against the new build on the next cycle, which is correct behavior, not a regression to defend against with extra retention.

12. **This repo is PUBLIC open source, and so is the phone repo. No secret may enter the source tree — or the shipped binary.** `github.com/Chessever/chessever_frontend_desktop` and `github.com/Chessever/chessever-frontend` are both public. Write every line as if a stranger reads it the minute it is pushed, because automated scrapers do exactly that. There are **two** exposure channels, and the second is the one that keeps getting missed:

    - **Channel 1 — git.** Anything committed to any branch of either repo is public the moment it is pushed. Deleting it later does not help: it was already scraped, and it stays in forks, PR refs, and the GitHub events API. A leaked credential is burned permanently; the only remedy is rotation at the issuer.
    - **Channel 2 — the app binary.** A Flutter client cannot keep a secret from its own user. A Dart `const`, a `--dart-define`, a value read from a bundled `.env` asset — all of them are compiled into the AOT snapshot as plaintext and come back out with `strings App | grep`. Every DMG, `.exe`, AppImage, APK and IPA we publish is a public artifact. **Making the repo private would not have prevented this.** "Move it to `.env`" is not a fix, it is the same leak with an extra step.

    Therefore: **any credential that grants write, admin, send, or impersonation rights lives server-side only.** The client calls an endpoint we control (Supabase edge function, Cloudflare worker, release droplet); that endpoint holds the key and enforces rate limits and abuse rules. The client never sees it.

    Values that *are* safe to ship in the client are the ones designed to be public and defended on the server: the Supabase **anon** key (RLS is the actual boundary), Firebase `apiKey` (a project identifier, not a credential), public API base URLs. If leaking a value lets someone act *as us*, it is not in this category. Never put a real credential in `.env.example`, and never uncomment the `.env` entry in `pubspec.yaml`'s asset list (it is commented out on purpose — bundling `.env` puts every key in it straight into channel 2).

    **Precedent, 2026-08-03:** `TelegramNotificationService` carried the feedback bot token as a hardcoded `const` next to the private group's chat ID. It went public with the OSS release on 2026-06-01, shipped in every release binary, and was harvested; the attacker used the Bot API to rename `@chesseverfeedbackbot` into a casino advert and gained send access to the internal feedback group. The token had to be revoked at BotFather — no code change could undo the leak. Assume the same fate for anything you hardcode.

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

On demand — read `docs/agents/desktop-ux-rules.md` before working on this area. Gist: The mobile app navigates through pushed routes.

## 5. Architecture (target)

On demand — read `docs/agents/architecture.md` before working on this area. Gist: Desktop screens reuse the existing `screens/<feature>/` widgets.

## 6. Package replacement matrix

On demand — read `docs/agents/package-replacement-matrix.md` before working on this area. Gist: Add: `forui`, `desktop_drop`, `window_manager` (or `bitsdojo_window`), `hotkey_manager`, `local_notifier`, `tray_manager` (optional), `sqflite_common_ffi`.
It is the desktop status of every mobile-only package — read it before adding, removing or gating any dependency.

## 7. Phases (the roadmap)

On demand — read `docs/agents/phases-roadmap.md` before working on this area. Gist: Foundation — write CLAUDE.md + AGENTS.md (this), bootstrap desktop runners, replace pubspec packages, wire `sqflite_common_ffi`, get `flutter run -d macos` past `main()`.

## 8. How to work on this repo

- Every iteration should leave the tree buildable on at least the current platform you're working on. If a package replacement breaks compilation for now, do it on a feature branch or land it together with its replacement.
- Read this file *and* `AGENTS.md` before you start. Read `lib/main.dart` for the current entry sequence.
- Never delete a mobile-only feature without first writing the desktop equivalent or putting it behind a `Platform` guard. Hot paths (auth, engine, persistence) get equivalents; cosmetic ones (in-app review prompts, ATT) get dropped.
- When introducing a new desktop file, place it under `lib/desktop/`. Don't pollute `lib/screens/` with desktop-only widgets.
- Tests live under `test/`. Add desktop-relevant tests next to the unit they cover.
- **Every commit that changes shipped code bumps `version:` in `pubspec.yaml`**, patch segment and build number together (`20.27.6+276` → `20.27.7+277`), with the new version at the end of the commit subject. The bump rides with the change, never as a follow-up `chore: bump`. Docs/test/CI-only commits are exempt. See `AGENTS.md` §2 — and note the phone repo now carries the same rule, so shared logic ported to both bumps both.
- `flutter analyze` clean is table stakes. `flutter run -d macos` and `flutter run -d windows` succeeding is the actual signal.

## 9. Definition of done (release-ready)

On demand — read `docs/agents/definition-of-done.md` before working on this area. Gist: The Ralph loop's completion promise will only be true when all of these hold:…

## 10. Anti-patterns (don't do these)

- ❌ Reimplementing the chess board, eval bar, or PV list because it "looks mobile-y." Resize and reuse. (Game cards in `desktop_game_card.dart` are NOT covered by this rule — redesign them however reads best on desktop.)
- ❌ Adding `if (kIsWeb)` branches for features. The browser build at
  app.chessever.com (`lib/web/`, `scripts/build_web.sh`, `scripts/deploy_web.sh`)
  runs this same shell as Wasm. Adapt platform mechanisms through browser
  implementations instead of hiding shared features. Keep it compiling: ask
  `lib/utils/host_platform.dart` (`hostIsMacOS`, …) instead of `dart:io`'s
  `Platform`, which throws in the browser, and import FFI packages through
  `lib/web/shims/`.
- ❌ Stuffing desktop-only logic into existing screen files. Add a desktop wrapper instead.
- ❌ Deleting a feature because the desktop equivalent is hard. File a tracked TODO and move on.
- ❌ Output the loop's completion promise when it isn't true. The promise text is in the loop config; only emit it when §9 is fully satisfied.
- ❌ Run `flutter build <target>` (macos/windows/ios/android/web) as your own validation step. Builds belong to the user and the release flow. `flutter analyze` is the signal; stop there.
- ❌ Hardcode a token, API key, bot token, webhook URL, private chat/channel ID, admin endpoint, or internal hostname anywhere under `lib/`. The repo is public and the binary is shippable — see §2.12. Route it through a server endpoint instead.
- ❌ "Fix" a leaked secret by moving it to `--dart-define`, a bundled `.env`, base64, or string-splitting. All of those still ship the value to the user; obfuscation is not secrecy. The only fix is that the client never holds it.
- ❌ Write a code comment, TODO, log line, error message, or test fixture that names internal infrastructure (droplet IPs, admin paths, private group IDs, staff usernames). It is published with everything else.

---

# Part II — Working agreements (formerly `AGENTS.md`; cited as `AGENTS.md §N`)

This file is the **operational** companion to `CLAUDE.md`. Read CLAUDE.md first for the *what* and *why*; read this for the *how*.

---

## TL;DR

You are porting a Flutter mobile app (chessever) to a native desktop app for **macOS and Windows**, designed as a **professional desktop chess database client**. Domain layer (repositories, providers, services) is reused as-is. The shell, navigation, layouts, and a handful of platform-bound packages are replaced.

The Ralph loop will keep waking you. Make every iteration land a verifiable, contained chunk of progress. Never lie to exit the loop.

**This repo is public open source, and so is the phone repo (`Chessever/chessever-frontend`).** Every line you write is readable by strangers the moment it is pushed, and every value you compile in is readable by anyone who downloads a release and runs `strings`. Nothing secret goes in `lib/`, ever — see CLAUDE.md §2.12 and §3 below.

---

## 1. Where to start each iteration

1. `git status` and `git log -n 10 --oneline` — see what previous iterations did.
2. Read `CLAUDE.md` §7 (phases). Identify the **current phase** by reading the tree (e.g. has `lib/desktop/` been created? does `pubspec.yaml` still contain `onesignal_flutter`?).
3. Run `flutter analyze` — if it's red, prefer fixing that before adding new work.
4. Use the task list (`TaskList` tool). Pick the lowest-id task that is `pending` and not blocked. Mark `in_progress` before you start.
5. Do one phase-coherent chunk. Don't half-finish three things.
6. Mark the task `completed` only when the chunk is real and verified (analyze clean for code changes, file exists for doc changes).

## 2. Branching and commits

- Stay on `main` unless the user gave you a branch.
- Desktop CI/CD uses GitHub Actions, not the Codemagic hosted service.
  Keep the five recipes in `codemagic.yaml` as the behavior reference and run
  `ruby scripts/ci/check_codemagic_parity.rb` when changing either workflow.
  Release workflows stay manually dispatched, with signing and R2 credentials
  behind the `main`-only `release` environment. Publishing to R2 is a manual
  release choice, not an automatic consequence of a push or store approval.
- Push commits and open a pull request only when the user explicitly asks.
- One commit per coherent chunk. Imperative subject, focused body.
- **Every commit that changes shipped code bumps `version:` in `pubspec.yaml`** — patch segment and build number together, both by one (`20.27.6+276` → `20.27.7+277`). The bump rides with the change that earned it; never leave it for a separate `chore: bump` commit. Put the resulting version at the end of the subject: `Suppress Game Report errors in retained decisive wins (20.27.7).` Docs-only, test-only, CI-only and tooling-only commits are exempt. The phone repo (`chessever-frontend`) follows the same rule, so shared logic ported to both — the Game Report classifier above all — bumps both.
- Do **not** commit unless the chunk leaves the tree in a buildable state (or the chunk *is* the buildable state).
- Never commit `.env`, `.env.e2e`, `.flutter-plugins-dependencies` (regenerated), `build/`, `.dart_tool/`, `flutter_*.png` debug screenshots.

## 3. Editing rules

- **Don't modify `lib/repository/**` or `lib/providers/**` unless** the change is required to make the existing API work on desktop (e.g. swapping sqflite for sqflite_common_ffi inside `AppDatabase`). Domain stability is what makes this port tractable.
- **Don't modify `lib/screens/**` widgets** to add desktop-only branches. Wrap them at a higher level under `lib/desktop/`.
- **Do** add `lib/desktop/...` files for new desktop UI.
- **Custom desktop buttons/controls match the sidebar button vocabulary.** The desktop sidebar items (`_SidebarItem` / `_SidebarHeaderButton` in `lib/desktop/shell/desktop_sidebar.dart`) are the canonical "our button" look for any bespoke clickable chrome (toolbar pills, action buttons above the board, etc.). Reuse the same recipe: rounded-8 pill, transparent→`kBlack3Color` hover fill, `kWhiteColor70`→`kWhiteColor` foreground, `kPrimaryColor`-tinted "primary/selected" state (fill `0.10`/hover `0.16`, border `0.35`, accent fg), thin `kDividerColor` resting border, icon ~16–18 + 13px `w600` label, and the `SingleMotionBuilder`+`DesktopMotion` hover/press nudge with `CursorAware`. Prefer this over a stock forui `FButton` when the control needs to feel native to the shell — a plain `FButton.outline` reads as generic/ugly next to the sidebar. (forui chrome — `FDialog`, `FTooltip`, menus, popovers — still stands per CLAUDE.md §3.)
- **Do** edit `lib/main.dart` to branch on platform when needed; keep the mobile path working.
- **Do** edit `pubspec.yaml`, `macos/`, `windows/` runner configs as needed.
- **Don't touch the updater pipeline unless the user explicitly asks for updater-pipeline changes.** The existing updater works and should be treated as stable. Avoid changes to `lib/desktop/services/desktop_updater.dart`, `desktop_updater_state.dart`, recovery/staged-marker services, release archive/diff/staging/install behavior, and `third_party/desktop_updater`. Additive native controls are allowed only when requested and should call the existing public API (`checkForUpdates`, `applyUpdate`, `openDownloadPage`) without changing updater internals.
- **Don't** rename existing public types unless you also update every callsite in the same commit.
- **Never bypass local chess cache write serialization.** `resqlite`'s writer mutex is scoped to one `Database.open(...)` instance. It does not protect us when Library/Players/import code opens another handle to the same `chessever_local_chess.db`. Do not add path-only import writers, purge writers, tree/cache rebuild writers, stat refresh writes, or source-sync writes that touch the same file outside `LocalChessDatabaseRepository._runLocalCacheWriteQueued` (or a public repository method that already uses it). Prefer reusing the open app cache connection. If a separate connection is truly required, serialize the entire write lifetime through the shared queue, keep it short-lived, close it deterministically, and add a regression test for the same-file concurrent writer case.
- **Never rename or arch-suffix the Apple Silicon macOS release artifacts.** Silicon is the original macOS release and its identifiers are frozen: updater platform key / archive slug / `ingest` arg `macos` (bare), stable DMG `Chessever.dmg`, versioned DMG `Chessever-<version>.dmg`. Intel was added later and is strictly additive: `macos-x64`, `Chessever-intel.dmg`, `Chessever-<version>-intel.dmg`. `scripts/codemagic_publish_macos.sh` already encodes this in `UPDATE_PLATFORM` / `DMG_ARCH_LABEL` / `STABLE_DMG_NAME`; leave the Silicon branch alone. Do not make the two branches "symmetric" — every installed macOS client polls `platform: macos`, and the website Mac link resolves `Chessever.dmg`. `Chessever-arm64.dmg` is **not** a download to link to — the release flow writes it only as a copy of `Chessever.dmg` for the stranded 264/265 builds. New macOS variants get new names added beside the frozen ones. See CLAUDE.md §2.10.
- **Never put a secret in `lib/` — the repo is public and the binary ships to users.** No bot tokens, API keys, webhook URLs, private chat/channel IDs, admin endpoints, or internal hostnames as Dart constants, `--dart-define` values, or bundled `.env` assets. All of those are recoverable from a published DMG/exe/AppImage/APK with `strings`, so making the repo private would not save you. Any credential granting write/send/admin/impersonation rights belongs behind a server endpoint we control (Supabase edge function, Cloudflare worker, release droplet) that holds the key and rate-limits the caller; the client posts to our endpoint and nothing else. Client-safe values are only the ones designed to be public and defended server-side: Supabase **anon** key (RLS is the boundary), Firebase `apiKey`, public base URLs. Keep the `# - .env` line in `pubspec.yaml`'s asset list commented out. When you need a new third-party integration, the first design question is "where does the key live", and the answer is never "in the app". See CLAUDE.md §2.12 for the 2026-08-03 Telegram bot-token incident that produced this rule.
- **Never raise `KEEP_LAST_N` above 1.** `scripts/codemagic_publish_wrapper.sh` keeps exactly one release per platform on the release server (one archive dir, one `app-archive.json` item, one versioned download; stable aliases are overwritten in place and don't count). The updater only ever targets the highest `shortVersion` and rollback is a new forward build, so older archives are unreachable dead weight — and at ~1.3 GB per release across four platforms they are what fills the droplet disk. See CLAUDE.md §2.11.

## 4. Package changes

On demand — read `docs/agents/package-changes.md` before working on this area. Gist: When removing a mobile-only package:…

## 5. Stockfish replacement (the hard one)

On demand — read `docs/agents/stockfish-replacement.md` before working on this area. Gist: Pub package `stockfish` is mobile-only because it bundles native libs for Android/iOS.
Never add `assets/engine/linux/stockfish` to `pubspec.yaml` — the Linux build script injects it so mac/Windows downloads stay 78 MB lighter.

## 6. Auth (the second-hardest)

On demand — read `docs/agents/desktop-auth.md` before working on this area. Gist: Google: ditch `google_sign_in`. Use OAuth 2.0 desktop flow: 1.

## 7. Window, shell, and shortcuts

- `window_manager` (preferred) for window state, min size, hiding before first frame, fullscreen.
- `hotkey_manager` for global hotkeys when needed; otherwise prefer `Shortcuts`/`Actions`/`Focus` Flutter primitives for in-app shortcuts.
- Global search is always available: `Cmd+Shift+F` on macOS and `Ctrl+Shift+F` on Windows must open global search from every route, pane, and feature state. New Library/Players subviews, nested navigators, focus scopes, text fields, and feature shortcuts must not shadow or disable this shell-level shortcut.
- **Use `forui` components for desktop chrome — this is mandatory, not a preference.** That includes: `FTooltip`, `FDialog`, `FPopover`, `FSelect`/`FSelectMenu`, `FButton`, `FSwitch`, `FSlider`, command palette host, sheets, dropdowns. Anywhere `lib/desktop/` would otherwise reach for a Material chrome widget, use forui instead.
  - **Banned in `lib/desktop/`:** `material.Tooltip`, `material.PopupMenuButton`, `material.Dialog`/`showDialog` for chrome dialogs, `material.DropdownButton`, `material.BottomSheet`, Material `IconButton`, Material `TextButton`, and button-like Material tap targets such as `InkWell` for desktop chrome (use a forui sheet, right-pane inspector, `FButton`, or a forui-backed helper instead).
  - **Why this matters concretely:** Flutter 3.41.9 rewrote Material `Tooltip` on top of an internal `RawTooltip`. Both share `SingleTickerProviderStateMixin`; the new lazy-controller path asserts ("multiple tickers were created") when chrome tooltips reparent during tab switches. forui's `FTooltip` uses an independent state tree and doesn't trip the assertion.
  - **Helper wrappers, not raw forui in panes.** Add a thin helper under `lib/desktop/widgets/` (e.g. `desktop_tooltip.dart` → `DesktopTooltip`) that supplies the project's defaults (350 ms hover, dark `FThemes.zinc.dark`) and call the helper from panes. New chrome primitive → new helper next to the existing ones.
  - **`FTheme` ancestor is required.** forui widgets read `context.theme`. Scope it locally when injecting into a Material subtree (the helper does this), or wrap the shell once if you've migrated the whole shell. Don't sprinkle stray `FTheme` ancestors mid-tree.
  - **Don't replace existing in-screen widgets with forui equivalents** — only the chrome is forui. Board, eval bar, PV list etc. stay as-is.
- Persist window bounds and pane splitter positions in SQLite via the existing `AppDatabase`.

## 8. Verification checklist (run before marking a task complete)

- [ ] `flutter analyze` clean on changed files. **This is the only validation signal you run.** Do **not** run `flutter build` or `flutter run` to self-verify — builds belong to the user and the release flow. Analyze clean = chunk verified.
- [ ] If you touched a domain repository: existing mobile path still compiles (`flutter analyze` covers this).
- [ ] If you replaced a package: `pubspec.yaml` no longer references the old one; `pubspec.lock` regenerated.
- [ ] If you added a UI surface: keyboard navigation works without using the mouse (reasoned from code, not a runtime check).
- [ ] If you added or changed a route, pane, focus scope, text field, shortcut map, or nested Library/Players view: global search still works from that surface (`Cmd+Shift+F` on macOS, `Ctrl+Shift+F` on Windows).
- [ ] If you touched `scripts/codemagic_publish_macos.sh`, `codemagic.yaml`, or anything naming a macOS release artifact: Silicon still publishes as platform `macos` + `Chessever.dmg` + `Chessever-<version>.dmg`, and Intel changes stayed additive (`macos-x64` / `-intel`).
- [ ] **Secret check on every commit.** Nothing you are about to commit contains a credential, token, key, webhook URL, private chat/channel ID, or internal hostname. Cheap gate before you commit: `git diff --cached -U0 | grep -nIE '[0-9]{8,10}:[A-Za-z0-9_-]{35}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|service_role|-----BEGIN [A-Z ]*PRIVATE KEY|api[_-]?key\s*[:=]\s*.[A-Za-z0-9]{16,}'` — any hit is a stop-and-rethink, not a "well it's only internal".
- [ ] If you touched Library/Players local chess cache code, source imports, deletes, purges, stat refreshes, or tree/cache rebuilds: no new same-file `resqlite.Database.open` writer bypasses the shared local chess write queue, and tests cover the relevant queue/concurrency path.

## 9. Things to never do

- ❌ Run `flutter clean` and commit the resulting state. Just don't.
- ❌ Edit `pubspec.lock` by hand. Always via `flutter pub get`.
- ❌ Commit binary changes to `macos/Runner/Assets.xcassets` or `windows/runner/resources/` without explicit reason.
- ❌ Disable analyzer rules to make a build green. Fix the code.
- ❌ Output the Ralph loop's completion promise unless every checkbox in `CLAUDE.md` §9 is true. The loop will run forever rather than ship a half-built app — that is by design.
- ❌ Commit a secret "temporarily", "just for testing", or "it's only a low-value token". This repo is public; a push is a publication, and rotation at the issuer is the only remedy afterwards.
- ❌ Obfuscate a shipped secret (base64, split strings, `--dart-define`, XOR) and call it fixed. The user's own device has to decode it to use it, so the user can decode it. Move it server-side or drop the feature.
- ❌ Run `flutter build macos`, `flutter build windows`, or any `flutter build <target>` to validate your work. Builds are slow, produce artifacts the repo doesn't track, and are the user's / release flow's job. `flutter analyze` is the validation signal — full stop. Same for `flutter run`: don't auto-launch the app to smoke-test.

## 10. When you're stuck

- If a package has no obvious desktop replacement, drop it (with a CLAUDE.md note in the matrix) rather than blocking the loop.
- If a UI pattern doesn't translate (e.g. mobile bottom sheets), pick a desktop equivalent (right inspector pane, modal dialog, dropdown) and document the choice.
- If you don't know what to do this iteration, run `flutter analyze` — the next thing to fix usually shouts at you from there.

---

End of AGENTS.md.

## Desktop distribution editions

Maintain the four website downloads (macOS Apple Silicon, macOS Intel, Windows,
Linux) and the separate Mac App Store edition from `main`. **The two macOS
editions are the same code but do not behave the same.** Only
`scripts/build_mac_app_store.sh` enables `MAC_APP_STORE=true` together with
native `CHESSEVER_APP_STORE=YES`. In Dart every difference goes through
`isMacAppStore` (`lib/desktop/services/mac_app_store.dart`), which is false in
every website build. Never apply store sandbox, billing or sign-in behavior to
the direct-download lanes, and never route the store edition through a website
path.

| | Website downloads (Developer ID macOS, Windows, Linux) | Mac App Store edition |
|---|---|---|
| Apple sign-in | Sent to the web: Supabase-hosted Apple OAuth in the default browser, back through the loopback callback (`SupabaseOAuthLoopback`) | In the app: the native Sign in with Apple sheet (`_signInWithAppleNatively` → `signInWithIdToken`). App Review guideline 4 forbids leaving the app |
| Google sign-in | Loopback OAuth in the default browser | Same loopback flow, but the page opens in an in-app `ASWebAuthenticationSession` sheet (`DesktopAuthBrowser`, `macos/Runner/DesktopWebAuthBridge.swift`) |
| Subscriptions | Stripe Checkout through chessever.com; cancelling goes to the web account page | RevenueCat with App Store in-app purchases (`MacAppStoreBilling`, `MacAppStorePlans`; same account id and `Chessever Subscription` entitlement as mobile). Stripe checkout throws here |
| Updates | `desktop_updater` and the Settings Updates card | The App Store. The updater and its UI are off |
| Engines | Bundled or downloaded into Application Support | Sealed helpers in `Contents/Helpers` only (`macAppStoreBundledPath`); nothing is extracted, downloaded or discovered elsewhere |
| Files | Unsandboxed | App Sandbox: only user-picked files and folders, retained through `MacSandboxFilePicker` (security-scoped bookmarks) |
| Signing | `Release.entitlements`, Developer ID | `AppStore.entitlements` (+ `AppStoreHelper.entitlements` for helpers) and the store provisioning profile |
| Feedback, analytics | Screenshot on by default | Screenshot off by default, feedback needs a session, ad consent denied |

The browser build at app.chessever.com (`lib/web/`) is a third distribution
of the same shell, gated by `kIsWeb`. Its sign-in is Supabase-hosted OAuth
that redirects back to the page (PKCE), because a tab cannot run the loopback
server. It has no installer updater: `DesktopUpdaterService` watches for a
newer deploy (`lib/web/web_release_watcher.dart`) and the update chip
reloads the page. `docs/web_build_feature_parity.md` lists what else differs. Put a `kIsWeb` check before an `isMacAppStore` one, so
native builds take the same branch as before.

### Web port parity and synchronized updates

**app.chessever.com is the web port of this desktop app, with full feature
parity as the goal.** This repository owns its Flutter source and deployment:
`lib/web/web_main.dart` boots the shared `lib/desktop/` shell. The sibling
`../chessever_web_frontend` repository owns the separate Next.js site at
chessever.com, not the app.chessever.com deployment. Keep this policy in both
repositories' `AGENTS.md` files.

- For every desktop feature, fix, auth change or shared behavior change,
  assess and update the browser path in the same change. Reuse shared widgets,
  providers and domain logic; add browser adapters only for platform mechanisms.
  Hiding a feature behind a platform check does not satisfy parity.
- Keep keyboard behavior, account/guest transitions, library and analysis data,
  imports/exports and persistence equivalent. Browser-native mechanisms such
  as OAuth redirects, IndexedDB and downloads can differ while preserving the
  user's capability. Preserve the website and Mac App Store edition branches.
- Track actual browser limitations and remaining feature gaps in
  `docs/web_build_feature_parity.md`, including their cause and follow-up.
  Those gaps are work to close, not permanent exemptions. Report any new gap
  rather than claiming full parity or silently disabling the feature.
- Publish the web port alongside authorized desktop releases from the same
  source revision and `pubspec.yaml` version. Use `scripts/build_web.sh` with
  allowlisted public configuration, then `scripts/deploy_web.sh`; never deploy
  an older worktree's `build/web`. Building assets for a requested deployment
  is a release action; the ban on builds as self-verification still applies.
- Check shared changes with focused tests and `flutter analyze`, reason through
  browser APIs, and exercise the affected browser surface when available.
  After deployment, verify the active Worker and the served `/version.json`
  against the intended version/build. A desktop push alone does not update
  app.chessever.com. State explicitly if web deployment or verification remains
  incomplete.

When a change touches sign-in, billing or the paywall, updates, engine paths,
file access, entitlements, feedback or analytics:

- Keep the existing `isMacAppStore` branch, and reason through both editions.
  Test both. `desktop_in_app_sign_in_test.dart` and
  `desktop_website_sign_in_test.dart` are the pattern.
- A new capability (camera, microphone, network server, a new helper binary)
  is denied in the store edition until it is added to `AppStore.entitlements`
  on purpose. App Review sees every entitlement. Either add it with a
  justification or hide the feature when `isMacAppStore` is true.
- Don't put Mac or macOS in the store listing's name, subtitle or screenshot
  captions (guideline 5.2.5). The listing name is "ChessEver".

Release instructions: `docs/ci/github-actions-release.md`. The Mac App Store
workflow must upload and submit for review with `releaseType=MANUAL`; never add
automatic release after approval. Do not cancel a pending review unless the
operator explicitly selects replacement. Keep App Store signing assets separate
from Developer ID signing assets, and out of source, Dart defines and artifacts.

---

## Forui

On demand — read `docs/agents/forui.md` before working on this area. Gist: This repo pins `forui: ^0.16.0` (`pubspec.yaml`).
forui.dev documents the latest release — check every API against 0.16 and never blind-bump forui (0.24+ removed `FThemes.zinc.dark`, which the whole shell uses).
