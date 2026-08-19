# AGENTS.md — Working agreements for any agent in this repo

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
- **Never put a secret in `lib/` — the repo is public and the binary ships to users.** No bot tokens, API keys, webhook URLs, private chat/channel IDs, admin endpoints, or internal hostnames as Dart constants, `--dart-define` values, or bundled `.env` assets. All of those are recoverable from a published DMG/exe/AppImage/APK with `strings`, so making the repo private would not save you. Any credential granting write/send/admin/impersonation rights belongs behind a server endpoint we control (Supabase edge function, Cloudflare worker, release droplet) that holds the key and rate-limits the caller; the client posts to our endpoint and nothing else. Client-safe values are only the ones designed to be public and defended server-side: Supabase **anon** key (RLS is the boundary), Firebase `apiKey`, public base URLs. Keep the `# - .env` line in `pubspec.yaml`'s asset list commented out. When you need a new third-party integration, the first design question is "where does the key live", and the answer is never "in the app". See CLAUDE.md §2.12 for the 2026-08-03 Telegram bot-token incident that produced this rule.
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

---

## Forui

> Beautiful, minimalistic, and platform-agnostic UI library for Flutter.

**This repo pins `forui: ^0.16.0`** (`pubspec.yaml`). forui.dev serves the latest
release, so check an API against the pinned version before using it — 0.24
deleted every theme preset except Neutral (`FThemes.zinc.dark`, which the whole
desktop shell uses, is gone there), 0.25 changed the missing-`FTheme` fallback
from zinc-light to `FTheme.neutral.light.touch`, and several
`FButtonStyle.ghost((s) => s.copyWith(...))` customizations no longer exist. Do
not blind-bump; a correct upgrade means generating a custom dark theme
(`dart run forui theme create`) that matches zinc-dark and wrapping the app once.

- [About Forui](https://forui.dev/docs.md): Beautiful, minimalistic, and platform-agnostic UI library for Flutter.
- [Getting Started](https://forui.dev/docs/getting-started.md): Get started with Forui in your Flutter project.

### Concepts

- [Themes](https://forui.dev/docs/concepts/themes.md): Define consistent visual styles across your Flutter application with Forui's theming system.
- [Controls](https://forui.dev/docs/concepts/controls.md): Abstractions over controllers that define where widget state lives.
- [Localization](https://forui.dev/docs/concepts/localization.md): Enable localization for Forui widgets across 115 languages.
- [Responsive](https://forui.dev/docs/concepts/responsive.md): Platform variants and responsive breakpoints for adaptive layouts.

### Guides

- [Adding Theme Properties](https://forui.dev/docs/guides/adding-theme-properties.md): Extend Forui themes with application-specific properties using Flutter's ThemeExtension system.
- [Customizing Themes](https://forui.dev/docs/guides/customizing-themes.md): Generate and customize themes and widget styles using the CLI.
- [Customizing Widget Styles](https://forui.dev/docs/guides/customizing-widget-styles.md): Customize individual widget styles using deltas and the CLI.
- [Customizing Icons](https://forui.dev/docs/guides/customizing-icons.md): Swap the icons used by Forui widgets with your own icons.
- [Creating Custom Deltas](https://forui.dev/docs/guides/creating-custom-deltas.md): Create custom delta classes for transformations not provided out of the box.
- [Creating Custom Controllers](https://forui.dev/docs/guides/creating-custom-controllers.md): Extend Forui controllers with custom logic and pass them to widgets.
- [Using Forui À La Shadcn/ui](https://forui.dev/docs/guides/using-forui-a-la-shadcn-ui.md): Take full ownership of Forui's behavior and layout by editing widget source directly.

### Reference

- [CLI](https://forui.dev/docs/reference/cli.md): Generate themes and styles in your project with Forui's CLI.
- [Icons](https://forui.dev/docs/reference/icon-library.md): High-quality Lucide icons bundled with Forui.
- [Hooks](https://forui.dev/docs/reference/hooks.md): First-class Flutter Hooks integration with Forui controllers.
- [LLMs](https://forui.dev/docs/reference/llms.md): Machine-readable documentation for LLMs and AI-powered tools.

### Widgets

#### Layout

- [Divider](https://forui.dev/docs/widgets/layout/divider.md): Visually or semantically separates content.
- [Resizable](https://forui.dev/docs/widgets/layout/resizable.md): A box which children can be resized along either the horizontal or vertical axis.
- [Scaffold](https://forui.dev/docs/widgets/layout/scaffold.md): Creates a visual scaffold for Forui widgets.

#### Form

- [Autocomplete](https://forui.dev/docs/widgets/form/autocomplete.md): An autocomplete provides a list of suggestions based on the user's input and shows typeahead text for the first match. It is a form-field and can therefore be used in a form.
- [Button](https://forui.dev/docs/widgets/form/button.md): A button.
- [Checkbox](https://forui.dev/docs/widgets/form/checkbox.md): A control that allows the user to toggle between checked and not checked.
- [Date Field](https://forui.dev/docs/widgets/form/date-field.md): A date field allows a date to be selected from a calendar or input field.
- [Date Time Picker](https://forui.dev/docs/widgets/form/date-time-picker.md): A date and time picker that allows a date and time to be selected. The picker supports arrow key navigation. Recommended for touch devices.
- [Label](https://forui.dev/docs/widgets/form/label.md): Describes a form field with a label, description, and error message (if any). This widget is usually used for custom form fields. All form fields in Forui come with this widget wrapped.
- [Multi Select](https://forui.dev/docs/widgets/form/multi-select.md): A multi select displays a list of drop-down options for the user to pick from. It is a form-field and can therefore be used in a form.
- [OTP Field](https://forui.dev/docs/widgets/form/otp-field.md): A one-time password input field for verification codes.
- [Picker](https://forui.dev/docs/widgets/form/picker.md): A generic picker that allows an item to be selected. It is composed of one or more wheels, optionally with separators between those wheels. The picker supports arrow key navigation. Recommended for touch devices.
- [Radio](https://forui.dev/docs/widgets/form/radio.md): A radio button that typically allows the user to choose only one of a predefined set of options.
- [Select Group](https://forui.dev/docs/widgets/form/select-group.md): A group of items that allow users to make a selection from a set of options.
- [Select](https://forui.dev/docs/widgets/form/select.md): A select displays a list of drop-down options for the user to pick from. It is a form-field and can therefore be used in a form.
- [Slider](https://forui.dev/docs/widgets/form/slider.md): A sliding input component that allows users to select a value within a specified range by dragging a handle or tapping on the track.
- [Switch](https://forui.dev/docs/widgets/form/switch.md): A toggle switch component that allows users to enable or disable a setting with a sliding motion.
- [Text Field](https://forui.dev/docs/widgets/form/text-field.md): A text field lets the user enter text, either with a hardware keyboard or with an onscreen keyboard.
- [Text Form Field](https://forui.dev/docs/widgets/form/text-form-field.md): A text field that can be used in forms, allowing the user to enter text, either with a hardware keyboard or with an onscreen keyboard.
- [Time Field](https://forui.dev/docs/widgets/form/time-field.md): A time field allows a time to be selected from a picker or input field.
- [Time Picker](https://forui.dev/docs/widgets/form/time-picker.md): A time picker that allows a time to be selected. The picker supports arrow key navigation. Recommended for touch devices.

#### Data Presentation

- [Accordion](https://forui.dev/docs/widgets/data/accordion.md): A vertically stacked set of interactive headings that reveal associated content sections when clicked. Each section can be expanded or collapsed independently.
- [Avatar](https://forui.dev/docs/widgets/data/avatar.md): A circular image component that displays user profile pictures with a fallback option. The Avatar component provides a consistent way to represent users in your application, displaying profile images with fallbacks to initials or icons when images are unavailable.
- [Badge](https://forui.dev/docs/widgets/data/badge.md): A badge draws attention to specific information, such as labels and counts. Use badges to display status, notifications, or small pieces of information that need to stand out.
- [Calendar](https://forui.dev/docs/widgets/data/calendar.md): A calendar component for selecting and editing dates.
- [Card](https://forui.dev/docs/widgets/data/card.md): A flexible container component that displays content with an optional title, subtitle, and child widget. Cards are commonly used to group related information and actions.
- [Item Group](https://forui.dev/docs/widgets/data/item-group.md): An item group that typically groups related information together.
- [Item](https://forui.dev/docs/widgets/data/item.md): An item is typically used to group related information together.
- [Line Calendar](https://forui.dev/docs/widgets/data/line-calendar.md): A compact calendar component that displays dates in a horizontally scrollable line, ideal for date selection in limited space.

#### Tile

- [Select Menu Tile](https://forui.dev/docs/widgets/tile/select-menu-tile.md): A tile that, when triggered, displays a list of options for the user to pick from.
- [Select Tile Group](https://forui.dev/docs/widgets/tile/select-tile-group.md): A group of tiles that allow users to make a selection from a set of options.
- [Tile Group](https://forui.dev/docs/widgets/tile/tile-group.md): A tile group that typically groups related information together.
- [Tile](https://forui.dev/docs/widgets/tile/tile.md): A specialized Item for touch devices, typically used to group related information together.

#### Navigation

- [Bottom Navigation Bar](https://forui.dev/docs/widgets/navigation/bottom-navigation-bar.md): A bottom navigation bar is usually present at the bottom of root pages. It is used to navigate between a small number of views, typically between three and five.
- [Breadcrumb](https://forui.dev/docs/widgets/navigation/breadcrumb.md): Displays a list of links that help visualize a page's location within a site's hierarchical structure. It allows navigation up to any of the ancestors.
- [Header](https://forui.dev/docs/widgets/navigation/header.md): A header contains the page's title and navigation actions. It is typically used on pages at the root of the navigation stack.
- [Pagination](https://forui.dev/docs/widgets/navigation/pagination.md): Display the current active page and enable navigation between multiple pages.
- [Sidebar](https://forui.dev/docs/widgets/navigation/sidebar.md): A sidebar widget that provides an opinionated layout for navigation on the side of the screen.
- [Tabs](https://forui.dev/docs/widgets/navigation/tabs.md): A set of layered sections of content—known as tab entries—that are displayed one at a time.

#### Feedback

- [Alert](https://forui.dev/docs/widgets/feedback/alert.md): Displays a callout for user attention.
- [Circular Progress](https://forui.dev/docs/widgets/feedback/circular-progress.md): Displays an indeterminate circular indicator showing the completion progress of a task.
- [Determinate Progress](https://forui.dev/docs/widgets/feedback/determinate-progress.md): Displays a determinate linear indicator showing the completion progress of a task.
- [Progress](https://forui.dev/docs/widgets/feedback/progress.md): Displays an indeterminate linear indicator showing the completion progress of a task.

#### Overlay

- [Context Menu](https://forui.dev/docs/widgets/overlay/context-menu.md): A context menu displays a menu at the user's pointer.
- [Dialog](https://forui.dev/docs/widgets/overlay/dialog.md): A modal dialog interrupts the user with important content and expects a response.
- [Persistent Sheet](https://forui.dev/docs/widgets/overlay/persistent-sheet.md): A persistent sheet is displayed above another widget while still allowing users to interact with the widget below.
- [Popover Menu](https://forui.dev/docs/widgets/overlay/popover-menu.md): A popover menu displays a menu in a portal aligned to a child.
- [Popover](https://forui.dev/docs/widgets/overlay/popover.md): A popover displays rich content in a portal that is aligned to a child.
- [Sheet](https://forui.dev/docs/widgets/overlay/sheet.md): A modal sheet is an alternative to a menu or a dialog and prevents the user from interacting with the rest of the app.
- [Toast](https://forui.dev/docs/widgets/overlay/toast.md): An opinionated toast that temporarily displays a succinct message.
- [Tooltip](https://forui.dev/docs/widgets/overlay/tooltip.md): A tooltip displays information related to a widget when focused, hovered over, or long pressed.

#### Foundation

- [Collapsible](https://forui.dev/docs/widgets/foundation/collapsible.md): A collapsible widget that animates between visible and hidden states.
- [Focused Outline](https://forui.dev/docs/widgets/foundation/focused-outline.md): An outline around a focused widget that does not affect its layout.
- [Overlay](https://forui.dev/docs/widgets/foundation/overlay.md): A low-level overlay primitive that composites content relative to a child widget.
- [Point Portal](https://forui.dev/docs/widgets/foundation/point-portal.md): A "floating" portal anchored at a specific point within a child widget's coordinate space.
- [Portal](https://forui.dev/docs/widgets/foundation/portal.md): A "floating" portal anchored relative to a child widget's edge.
- [Tappable](https://forui.dev/docs/widgets/foundation/tappable.md): An area that responds to touch.

### Full Documentation

- [Full documentation](https://forui.dev/docs/llms-full.txt)
