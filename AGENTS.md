# AGENTS.md — Working agreements for any agent in this repo

This file is the **operational** companion to `CLAUDE.md`. Read CLAUDE.md first for the *what* and *why*; read this for the *how*.

---

## TL;DR

You are porting a Flutter mobile app (chessever) to a native desktop app for **macOS and Windows**, designed as a **professional desktop chess database client**. Domain layer (repositories, providers, services) is reused as-is. The shell, navigation, layouts, and a handful of platform-bound packages are replaced.

The Ralph loop will keep waking you. Make every iteration land a verifiable, contained chunk of progress. Never lie to exit the loop.

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
- **Never rename or arch-suffix the Apple Silicon macOS release artifacts.** Silicon is the original macOS release and its identifiers are frozen: updater platform key / archive slug / `ingest` arg `macos` (bare), stable DMG `Chessever.dmg`, versioned DMG `Chessever-<version>.dmg`. Intel was added later and is strictly additive: `macos-x64`, `Chessever-intel.dmg`, `Chessever-<version>-intel.dmg`. `scripts/codemagic_publish_macos.sh` already encodes this in `UPDATE_PLATFORM` / `DMG_ARCH_LABEL` / `STABLE_DMG_NAME`; leave the Silicon branch alone. Do not make the two branches "symmetric" — every installed macOS client polls `platform: macos`, and the website Mac link resolves `Chessever.dmg`. `Chessever-arm64.dmg` is **not** a published artifact; nothing in the release flow writes it, so any link pointing there serves a stale orphan. New macOS variants get new names added beside the frozen ones. See CLAUDE.md §2.10.
- **Never raise `KEEP_LAST_N` above 1.** `scripts/codemagic_publish_wrapper.sh` keeps exactly one release per platform on the release server (one archive dir, one `app-archive.json` item, one versioned download; stable aliases are overwritten in place and don't count). The updater only ever targets the highest `shortVersion` and rollback is a new forward build, so older archives are unreachable dead weight — and at ~1.3 GB per release across four platforms they are what fills the droplet disk. See CLAUDE.md §2.11.

## 4. Package changes

When removing a mobile-only package:

1. Find every import: `grep -rn "package:<name>" lib/`.
2. For each callsite, either:
   - Replace with the desktop equivalent (preferred), **or**
   - Wrap in `if (!Platform.isMacOS && !Platform.isWindows) { ... }` if the call is mobile-only behavior we keep on mobile.
3. Remove the dependency from `pubspec.yaml`.
4. `flutter pub get` and confirm `flutter analyze` is clean.

When adding a desktop package:

1. Verify on pub.dev that it lists `macos` and `windows` (or both, if relevant).
2. Add to `pubspec.yaml` with a pinned `^x.y.z`.
3. Wire it minimally and verify it builds before broader use.

## 5. Stockfish replacement (the hard one)

- Pub package `stockfish` is mobile-only because it bundles native libs for Android/iOS.
- Replacement: ship a Stockfish binary per OS and drive it via UCI over stdio.
  - Place binaries under `assets/engine/macos/stockfish` and `assets/engine/windows/stockfish.exe`.
  - At runtime, copy the asset to the app support dir (`getApplicationSupportDirectory()`), `chmod +x` on macOS, then `Process.start` it.
  - Use a `StreamController<String>` over stdout to parse UCI; reuse the existing `StockfishSingleton` API surface so callers don't change.
- Reference: official Stockfish builds at https://stockfishchess.org/download/.
- This is a multi-iteration task. First iteration: get the interface and binary copy in place; second iteration: parse UCI and surface evals; third: tune hash/threads to desktop defaults.
- **⚠️ Linux engine is bundled DIFFERENTLY.** `pubspec.yaml`'s `flutter: assets:` list is shared across platforms, so anything listed there ships in *every* desktop app. macOS/Windows engines are listed in pubspec normally. The Linux engine (`assets/engine/linux/stockfish`, ~78 MB) is **committed but deliberately NOT in pubspec** — listing it would add 78 MB to the mac/Windows downloads. The Linux CI build (`scripts/codemagic_build_linux_release.sh`) **injects** the `- assets/engine/linux/stockfish` line into pubspec at build time (idempotent awk insert after the Windows entry); only the Linux bundle carries it. `uci_engine.dart` keeps the `Platform.isLinux` branch (no-op on mac/Win). **Never add the Linux line back to pubspec** — it reintroduces the bloat for mac/Win.

## 6. Auth (the second-hardest)

- Google: ditch `google_sign_in`. Use OAuth 2.0 desktop flow:
  1. Start `HttpServer.bind('127.0.0.1', 0)` to get a free port.
  2. Open browser to `https://accounts.google.com/o/oauth2/v2/auth?...&redirect_uri=http://127.0.0.1:<port>`.
  3. Capture the auth code from the loopback request, exchange via Supabase or directly with Google's token endpoint, then sign into Supabase with the resulting ID token.
- Apple: keep `sign_in_with_apple` only on macOS. On Windows, hide the button.
- Test signed-in state survives a restart on both OSes.

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
- [ ] If you touched Library/Players local chess cache code, source imports, deletes, purges, stat refreshes, or tree/cache rebuilds: no new same-file `resqlite.Database.open` writer bypasses the shared local chess write queue, and tests cover the relevant queue/concurrency path.

## 9. Things to never do

- ❌ Run `flutter clean` and commit the resulting state. Just don't.
- ❌ Edit `pubspec.lock` by hand. Always via `flutter pub get`.
- ❌ Commit binary changes to `macos/Runner/Assets.xcassets` or `windows/runner/resources/` without explicit reason.
- ❌ Disable analyzer rules to make a build green. Fix the code.
- ❌ Output the Ralph loop's completion promise unless every checkbox in `CLAUDE.md` §9 is true. The loop will run forever rather than ship a half-built app — that is by design.
- ❌ Run `flutter build macos`, `flutter build windows`, or any `flutter build <target>` to validate your work. Builds are slow, produce artifacts the repo doesn't track, and are the user's / release flow's job. `flutter analyze` is the validation signal — full stop. Same for `flutter run`: don't auto-launch the app to smoke-test.

## 10. When you're stuck

- If a package has no obvious desktop replacement, drop it (with a CLAUDE.md note in the matrix) rather than blocking the loop.
- If a UI pattern doesn't translate (e.g. mobile bottom sheets), pick a desktop equivalent (right inspector pane, modal dialog, dropdown) and document the choice.
- If you don't know what to do this iteration, run `flutter analyze` — the next thing to fix usually shouts at you from there.

---

End of AGENTS.md.
