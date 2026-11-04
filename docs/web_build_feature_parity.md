# Web build (app.chessever.com): feature parity and packages

## Required parity policy

The browser app is the shared-source port of the desktop app, and full feature
parity is the target. Ship shared desktop features and fixes to both paths in
the same change, and publish authorized releases from the same source revision
and application version. Browser-native mechanisms may differ while preserving
the capability. The limitations below remain work to close, not permanent
exclusions. Keep this inventory current and report new gaps explicitly.

This Flutter repository owns app.chessever.com (Worker `chessever-app`). The
sibling `chessever_web_frontend` repository owns the separate Next.js site at
chessever.com. Both `AGENTS.md` files carry the synchronized-update policy.

## Previous verification baseline

What the desktop shell does in a browser, how, and which pub.dev packages
were weighed for the gaps. Checked against pub.dev on 2026-10-28; build
22.17.15. Verified in headless Chromium and WebKit; Firefox and real Safari
still need a manual pass.

## Features

| Desktop feature | In the browser | How |
|---|---|---|
| Live events, games, players, calendar, rankings | Same | Shared code; images from hosts without CORS go through the `/_img` relay (`web_worker/index.js`, `web/index.html`) |
| Likes (community ranking from the phone's Discovery) | Same | Library > My Likes > Most liked (free) and the Events > For You shelf open `TabKind.likes` (`desktop_likes_pane.dart`); the `most_liked_ranking_page` RPC plus Gamebase lookups, no platform code. Shared `/app/likes/<period>` links route through `DesktopDeepLinkRouter` in both builds |
| Like a game from the board | Same | Heart button first in the board's action row (`board_like_button.dart`): writes the same Liked Games row as the phone, shows the `game_like_count` RPC count, and asks a guest to sign in (`showDesktopAccountSignIn`) before liking |
| Board, notation, explorer, keyboard shortcuts | Same | Browser-reserved chords (Cmd/Ctrl+W, T, Tab) also answer to Alt (`browser_safe_shortcuts.dart`) |
| Stockfish analysis and Play | Same | Stockfish 19 lite single-threaded Wasm in a Web Worker (`web/stockfish/`) |
| Maia bot | Same | onnxruntime-web through `lib/web/onnx_runtime_web.dart` |
| Leela (lc0) bot | Not available | No browser build of lc0; marked Unavailable and left out of tournament setup |
| Engine tournaments | Same | Conductor runs in the page; no loopback server |
| Local databases, opening trees, Prepare | Same | sqlite3 Wasm (`lib/web/shims/local_sqlite_web.dart`, the browser half of the local SQLite driver) over an IndexedDB-backed filesystem (`lib/web/web_file_system.dart`) |
| Import PGN, Paste, drag-and-drop files and folders, folder pickers | Same | Picked or dropped files are copied into browser storage (`web_file_intake.dart`); folders through `webkitdirectory` |
| Save / export PGN, save board image | Downloads | `lib/web/text_download.dart` |
| Copy board image | Clipboard | `ClipboardItem` (image/png) |
| Share board image | Browser share sheet | `share_plus` with `XFile.fromData` |
| Open game in new window, move tab to new window | New browser tab | The game's chessever.com address, same origin (`browser_tab.dart`); local-only games open as a tab |
| Picture-in-picture, tear-off tabs | Not available | Hidden on the web |
| Edit a PGN file in place | Chrome, Edge, Opera | Import keeps a File System Access handle; saved changes are written back to the user's file (`lib/web/linked_files_web.dart`). Firefox and Safari edit an imported copy; Export saves it |
| Show in folder, window position | Not applicable | Hidden on the web |
| Updates | Reload | Nothing to install: the tab compares its compiled `appBuildName`+`appBuildNumber` with the deploy's `/version.json` every 5 min and on refocus (`lib/web/web_release_watcher.dart`); a newer build shows the top-bar chip "New update available", and tapping it reloads the page. Settings has no Updates section on the web |
| Google and Apple sign-in | Same tab | Supabase-hosted OAuth redirecting back to the page (PKCE) instead of the loopback server; a pending guest merge waits in IndexedDB (`AppDatabaseGuestMergePendingStore`). The origin must be on the Supabase Auth redirect list |
| Addresses and history | chessever.com paths | `lib/web/web_url_sync.dart` owns the address bar and Back/Forward; Flutter's URL strategy is off |
| Startup page and How to use | Events at the bare domain; direct links keep their destination | Automatic How to use opens in a background tab on the web; native desktop onboarding keeps its existing focus behavior |
| Events membership | For You, Current and Calendar stay free; Past requires Premium | For You uses current broadcasts. Shared admission gate keeps Past unmounted until membership is verified; lookup failures offer Retry |
| Guest sign-up | First browser visit offers sign-in or Not now | The persisted guest clock survives reloads; reminders start at day 7, repeat weekly, and require sign-in at day 28. Signing in clears guest stamps |
| Sidebar number shortcuts | Same as desktop | Cmd/Ctrl+1 through 9, then 0 follow the primary sidebar routes from Events to Play; labels and bindings share `desktop_main_routes.dart` |

## Packages weighed (pub.dev, 2026-10-28)

| Package | In use | Latest | Decision |
|---|---|---|---|
| `web` | 1.1.1 | 1.1.2 | Used for every browser API above; patch update optional |
| `desktop_drop` | 0.6.1 | 0.9.2 (2026-10-20) | Stay. 0.9 fixes drops that carry no filesystem entry on the web, but rewrites the drop API (`onDrop`, `DropFileItem`, `cross_file` 0.4) across six files and every desktop platform; migrate together with a desktop test pass |
| `file_picker` | 8.3.7 | 13.3.0 (2026-10-26) | Stay. Picking with `withData` works on the web; folders use `webkitdirectory` directly |
| `sqlite3` | 3.8.0 (vendored `web/sqlite/sqlite3-3.8.0.wasm`, loaded by `lib/web/shims/local_sqlite_web.dart`) | 3.8.0 (2026-10-23) | Upgraded when `resqlite` was removed; now the local database driver on desktop and web. The vendored Wasm must match the package version exactly (a mismatch is a LinkError at load); upgrade both together, `test/web/local_sqlite_wasm_version_test.dart` checks it. `sqlite3-3.3.3.wasm` stays for one deploy so tabs opened before the 3.8.0 deploy can still load; delete it in the next web release |
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

## Service dependencies for the ticket fixes

Deploy the matching services before releasing the updated browser client:

- Gamebase must accept the book catalog sorts `lastGameAdded` and `publishedAt`
  and return nullable `lastGameAddedAt` in collection summaries. The default
  catalog order is the latest game addition first. This date comes from the
  creation time of games currently in the collection, independently of cover,
  metadata or game edits. Apply the additive `collection_game_added_idx`
  migration to keep those reads indexed. Older services reject the new sorts.
- The feedback relay must accept the exact `https://app.chessever.com` origin,
  answer its POST preflight, and include CORS headers on error responses as well
  as successful deliveries. Native clients continue to omit Origin.
- Botvinnik's chat service must recognize the browser client's
  `desktop-shell-v1` capability as the app at app.chessever.com, distinct from
  the public website. Its help lookup can select an explicitly requested phone,
  tablet, desktop, browser app or website without changing the request's account
  or device identity. AI-sharing consent remains per account in each browser.
