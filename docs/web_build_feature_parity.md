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
| Event card artwork | Same | `event_artwork_provider.dart` batches artwork-only tour queries, retains successful covers for 10 minutes across scrolling and tab switches, and retries a failed lookup once. Player metadata no longer delays cover requests; raw tour IDs still resolve sibling artwork |
| Likes (community ranking from the phone's Discovery) | Same | Library > My Likes > Most liked (free) and the Events > For You shelf open `TabKind.likes` (`desktop_likes_pane.dart`); the `most_liked_ranking_page` RPC plus Gamebase lookups, no platform code. Shared `/app/likes/<period>` links route through `DesktopDeepLinkRouter` in both builds |
| Like a game from the board | Phone guest policy | Heart button first in the board's action row (`board_like_button.dart`): writes the same Liked Games row as the phone and shows the `game_like_count` RPC count. Anonymous web accounts can like without a sign-up popup; native desktop keeps its existing account gate |
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
| Addresses and history | Shared paths and exact page state | Every shell surface has an explicit address; games, player sections, event rounds/scorecards, collections, calendar details, Likes and Miniatures mirror public paths. `WebUrlSync` owns Back/Forward, including same-tab game changes and board cursor/orientation. Flutter URL reporting stays off. See the Browser URL contract below |
| Startup page and How to use | Events at the bare domain; direct links keep their destination | Automatic How to use opens in a background tab on the web; native desktop onboarding keeps its existing focus behavior |
| Events membership | Event browsing stays free; archived event/game opens require Premium | Each opening resolves canonical Past membership and broadcast dates. Current events remain free unless another protected source applies; restored boards recheck access |
| Guest sign-up | First browser visit offers sign-in or Not now | The persisted guest clock survives reloads; reminders start at day 7, repeat weekly, and require sign-in at day 28. Signing in clears guest stamps |
| Phone rewarded features | Upgrade-only web paywall | My Likes/community games, PGN import/copy, every Game Report, Prep content, historical events and the other phone-gated surfaces require verified membership. Free browsing and the phone's latest-20 Likes export allowance remain available |
| First monthly subscription | $0.99 first month for eligible new subscribers, then the existing monthly price | Checkout verifies purchase history, active USD price and one-time discount server-side. App pricing shows the offer only after a matching server quote. Annual/native pricing is unchanged; the billing service must be deployed before either web frontend |
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

## Browser URL contract

The Flutter shell uses the same paths as chessever.com wherever the two sites
have the same destination. `app.` changes the renderer, not the game, player,
event, collection or calendar identity. Flutter's Navigator URL reporting stays
disabled; `WebUrlSync` is the sole browser-history owner.

| Surface | Path |
| --- | --- |
| Events and its discovery modes | `/broadcast?tab=current`, `for-you`, `past`, `search` |
| Event, selected round and event sections | `/broadcast/<slug>/<id>[/round/<roundId>][?tab=about|standings|bracket]` |
| Game and move cursor | `/games/<id>[?ply=<half-move>&flip=1]` |
| Standalone position or variation | `/analysis?fen=<FEN>[&flip=1]` |
| Player profile sections | `/player/<slug>/<identity>[/about|games|events]` |
| Historical player About | `/player/<slug>/<historical-identity>` |
| Event player and team scorecards | `/broadcast/<slug>/<id>/player/<fideId>`, `/team/<teamName>` |
| Calendar mode/month | `/calendar?mode=major|live|fide&month=YYYY-MM` |
| Calendar event | `/calendar/<slug>/fide-<id>` or `/calendar/<slug>/date-YYYY-MM-DD` |
| Published collection | `/collections/<slug>` |
| Database | `/databases/<folderId>`, `/databases/twic` |
| Likes | `/app/likes` (About), `/app/likes/<period>[?date=YYYY-MM-DD&view=players]` |
| Miniatures | `/app/miniatures/about`, `/games`, `/players` |
| Settings | `/broadcast/settings`, `/broadcast/settings?section=board` |
| Rankings, Play, Inbox, account, help | `/rankings`, `/play`, `/app/inbox`, `/account`, `/learn` |

App-only surfaces keep explicit addresses too: Library (`/databases`), Prepare
(`/players`), Favorites (`/favorites`), Countrymen (`/countrymen`), smart game
collections (`/games/search?collection=<kind>`), standalone opening explorer
(`/analysis?explorer=1`) and position editor (`/analysis?editor=1`). Local device
file paths and private PGNs never enter URLs.

`desktopWebBasePath` exhaustively covers every `TabKind`. New surfaces cannot
silently inherit `/`. Reserved list/tool words are dispatched before legacy
id-based deep links, so `settings` and `search` cannot become event/game ids.

One user action gets one browser entry, even when opening its tab and attaching
its arguments update different providers. Entries retain exact per-tab identities
and view state, not just tab ids. Back/Forward restores the board session as well
as its route; a closed tab reopens from its address. Native tab navigation and the
shell's global search shortcuts remain in their existing owners.

Tests: `flutter test test/desktop/desktop_web_location_test.dart
 test/desktop/desktop_tabs_test.dart test/desktop/desktop_deep_link_router_test.dart
 test/desktop/desktop_deep_link_incoming_test.dart`.
