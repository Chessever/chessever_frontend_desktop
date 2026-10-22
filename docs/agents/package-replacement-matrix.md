<!-- Moved verbatim from AGENTS.md Part I (formerly CLAUDE.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

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
| `purchases_flutter` | ✅ macOS store only | Mac App Store builds use Apple purchases through RevenueCat, with the same account/entitlement as mobile. Website and Windows builds retain Stripe and the backend subscription notifier; never initialize the Apple SDK there. |
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
