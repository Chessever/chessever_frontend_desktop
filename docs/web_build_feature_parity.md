# Web build (app.chessever.com): feature parity and packages

What the desktop shell does in a browser, how, and which pub.dev packages
were weighed for the gaps. Checked against pub.dev on 2026-10-28; build
22.17.15. Verified in headless Chromium and WebKit; Firefox and real Safari
still need a manual pass.

## Features

| Desktop feature | In the browser | How |
|---|---|---|
| Live events, games, players, calendar, rankings | Same | Shared code; images from hosts without CORS go through the `/_img` relay (`web_worker/index.js`, `web/index.html`) |
| Board, notation, explorer, keyboard shortcuts | Same | Browser-reserved chords (Cmd/Ctrl+W, T, Tab) also answer to Alt (`browser_safe_shortcuts.dart`) |
| Stockfish analysis and Play | Same | Stockfish 19 lite single-threaded Wasm in a Web Worker (`web/stockfish/`) |
| Maia bot | Same | onnxruntime-web through `lib/web/onnx_runtime_web.dart` |
| Leela (lc0) bot | Not available | No browser build of lc0; marked Unavailable and left out of tournament setup |
| Engine tournaments | Same | Conductor runs in the page; no loopback server |
| Local databases, opening trees, Prepare | Same | sqlite3 Wasm over an IndexedDB-backed filesystem (`lib/web/web_file_system.dart`) |
| Import PGN, Paste, drag-and-drop files and folders, folder pickers | Same | Picked or dropped files are copied into browser storage (`web_file_intake.dart`); folders through `webkitdirectory` |
| Save / export PGN, save board image | Downloads | `lib/web/text_download.dart` |
| Copy board image | Clipboard | `ClipboardItem` (image/png) |
| Share board image | Browser share sheet | `share_plus` with `XFile.fromData` |
| Open game in new window, move tab to new window | New browser tab | The game's chessever.com address, same origin (`browser_tab.dart`); local-only games open as a tab |
| Picture-in-picture, tear-off tabs | Not available | Hidden on the web |
| Edit a PGN file in place | Chrome, Edge, Opera | Import keeps a File System Access handle; saved changes are written back to the user's file (`lib/web/linked_files_web.dart`). Firefox and Safari edit an imported copy; Export saves it |
| Show in folder, auto-update, window position | Not applicable | Hidden on the web |
| Addresses and history | chessever.com paths | `lib/web/web_url_sync.dart` owns the address bar and Back/Forward; Flutter's URL strategy is off |

## Packages weighed (pub.dev, 2026-10-28)

| Package | In use | Latest | Decision |
|---|---|---|---|
| `web` | 1.1.1 | 1.1.2 | Used for every browser API above; patch update optional |
| `desktop_drop` | 0.6.1 | 0.9.2 (2026-10-20) | Stay. 0.9 fixes drops that carry no filesystem entry on the web, but rewrites the drop API (`onDrop`, `DropFileItem`, `cross_file` 0.4) across six files and every desktop platform; migrate together with a desktop test pass |
| `file_picker` | 8.3.7 | 13.3.0 (2026-10-26) | Stay. Picking with `withData` works on the web; folders use `webkitdirectory` directly |
| `sqlite3` | 3.3.3 (vendored `web/sqlite/sqlite3-3.3.3.wasm`) | 3.8.0 (2026-10-23) | Stay. The vendored Wasm must match the package version exactly (a mismatch is a LinkError at load); upgrade both together |
| `flutter_onnxruntime` | 1.6.4 | 1.9.0 (2026-10-06) | Not used on the web: its web plugin passes Dart objects to JavaScript, which fails in a Wasm build; Maia uses its own bindings |
| `stockfish` | 1.8.1 | 1.8.1 | Native only; the web build swaps in the Worker shim |
| `pasteboard` | 0.5.0 | 0.6.0 (2026-10-22) | Not needed on the web; images go through `ClipboardItem` |
| `share_plus` | 10.1.4 | 13.3.1 (2026-10-01) | Works on the web as is |
| `file_system_access_api` | not used | 2.0.0 (2024-01-19) | Unmaintained; the API is called through `web` instead (in-place editing above) |

## Still open

- Firefox and real Safari have not been driven: Playwright's Firefox cannot
  start from the agent sandbox here, and Safari needs a visible window.
  WebKit showed event covers black (`texImage2D: the ImageBitmap has been
  detached`), unconfirmed in Safari.
- Leela in the browser would need an ONNX-converted network and a search
  written in Dart.
