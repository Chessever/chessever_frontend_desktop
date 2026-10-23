## Browser build (app.chessever.com, experimental)

The desktop shell also compiles for the browser. It is hosted at
app.chessever.com from `ChessEver-Cloudflare/apps/app-web`. It is not a
release lane: nothing in the macOS, Windows, Linux or Mac App Store flows
builds or ships it, and none of its code paths run natively.

### Entry and shape

- `lib/main_web.dart` picks `lib/desktop/web/web_main.dart` under Wasm and
  `web_unsupported_main.dart` under dart2js.
- `web_main.dart` boots the same `DesktopApp` as `lib/main.dart`, minus what a
  tab cannot do: window management, extra board windows, picture-in-picture,
  the updater, single-instance forwarding, OS deep links, Firebase and local
  engines.

### Why Wasm only

dartchess uses 64-bit integers (bitboards). dart2js cannot represent them, so
the app does not compile to JavaScript. `flutter build web --wasm` still
compiles a dart2js fallback, which is why `main_web.dart` points dart2js at the
small unsupported-browser app.

`web/flutter_bootstrap.js` pins the skwasm renderer. It shows an HTML notice
instead of loading when the browser lacks WasmGC or is not Chromium-based,
because skwasm is only reliable on Chrome and Edge today. `?wasm=all` lets
other engines try. Under cross-origin isolation (set by the hosting), skwasm
renders on a worker thread.

### Writing code that also runs in the browser

- **`Platform`:** import it from `package:chessever/utils/platform/io_platform.dart`,
  never from `dart:io`. In the browser, every `dart:io` `Platform` getter
  throws, and one call during startup stops the app. The shim re-exports the
  real class natively, so native behaviour is unchanged. Where both are
  needed, write `import 'dart:io' hide Platform;`.
- **Host conventions:** for keyboard and menu conventions, use
  `desktopUsesMacKeyConventions` (`lib/desktop/utils/desktop_host_platform.dart`).
  It reads the host OS in the browser too.
- **Native-only code:** keep `dart:ffi`, processes, sockets and file paths
  behind a conditional import (`if (dart.library.js_interop)`), the way the
  existing seams do it: `local_pgn_rename`, `windows_shell_reveal`,
  `stockfish_raw_stdin`, `stockfish_upstream` and `resqlite`. An FFI import
  reachable from `web_main.dart` fails the Wasm build.
- **Browser-only code:** the reverse holds too. `dart:js_interop`,
  `dart:ui_web`, `package:web` and web plugin packages (`webview_all_web`,
  `sqflite_common_ffi_web`) live only in `*_web.dart` files behind such an
  import (`broadcast_video_browser_controller`, `desktop_db_web_factory`).
  `flutter analyze` does not flag one reached from native code, but the
  native compile, and every test that imports it, fails on `dart:ui_web`.
- **Desktop-only panes:** panes whose data or work lives on the user's
  computer are listed in `lib/desktop/web/desktop_web_support.dart`. Today
  these are Library (local databases), Prepare (downloaded player databases
  and trees) and Play (engines). The sidebar and command palette hide them,
  and a tab of that kind shows `DesktopAppOnlyPane`. Add a pane there, rather
  than sprinkling `kIsWeb` checks through it.
- **Window chrome:** `DesktopWindowFrame` and `DesktopDragToMoveArea` pass
  their child through in a tab. Do not call `windowManager` on a path that
  the browser reaches.
- **Local data:** the app database is SQLite in IndexedDB (sqflite's web
  backend, `desktop_db_web_factory_web.dart`). Engines are unavailable, and
  `stockfish_facade.dart` reports that.

### Sign-in

Google and Apple use Supabase's hosted OAuth with a redirect back to the page
(`DesktopAuthService._signInWithRedirect`, PKCE). The origin must be in the
Supabase project's Auth redirect URLs. The desktop loopback flow and its
client ID and secret are never part of a browser build.

### Plugins that need help in the browser

- **flutter_soloud:** its web module is loaded from Dart, in parallel with
  the first frame (`soloud_web_module.dart`), instead of by the `<script>`
  tags the plugin asks `index.html` for. The engine starts a few seconds
  after launch.
- **RevenueCat (`purchases_flutter`):** its web plugin fetches a ~1 MB SDK
  while plugins register. The browser edition does not bill through
  RevenueCat, so the finalize step serves an empty script at that URL.
- **google_sign_in_web:** it starts loading Google's GIS script while plugins
  register. The script is async and does not block the first frame. It
  cannot be avoided while `google_sign_in` stays a dependency of the shared
  mobile code.
- **Icon fonts:** Flutter's icon tree shaker reads the dart2js fallback's
  kernel, which would keep only the unsupported-browser app's icons. The
  build turns it off and subsets the icon fonts against a kernel of the Wasm
  app instead (`scripts/subset_web_icon_fonts.dart`).

### Build and deploy

```bash
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_ANON_KEY=sb_publishable_... \
  scripts/build_web.sh
```

- **Defines:** only the public values in `PUBLIC_DEFINES` are passed. The
  script refuses a secret or service-role Supabase key (CLAUDE.md §2.12).
- **sqlite3.wasm:** pinned to the `sqlite3` version in `pubspec.lock`, and
  checked against its SHA-256. Bump both together.
- **Finalize:** `scripts/finalize_web_build.dart` drops what the browser never
  loads (Stockfish binaries, CanvasKit, the dart2js output). It moves the app
  into `build/web/v/<content hash>/`, served immutable, and leaves
  `index.html` and the fixed-URL files at the root.
- **Deploy:** follow `apps/app-web/README.md` in ChessEver-Cloudflare.

For a local debug run, run `scripts/build_web.sh` once; it writes the
git-ignored `web/sqflite_sw.js` and `web/sqlite3.wasm`. Then:

```bash
flutter run -d chrome --wasm -t lib/main_web.dart \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```
