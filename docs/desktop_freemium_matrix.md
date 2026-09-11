# Desktop freemium entitlement matrix

## Authority and scope

- Desktop base: `e54f6884885069e3e3d641707cccf48735228303`, `origin/main`, Development `20.32.13+362`.
- Phone authority: `Chessever/chessever-frontend`, `origin/dev` at **`57ff22376a46777f83de238bdcc9502daf8c53c6`**, version **`28.15.0+2905`** (`pubspec.yaml:19`). This is an audited source snapshot, not a claim about the version currently installed from an app store.
- Phone paths below are relative to that exact SHA. They can be opened under `https://github.com/Chessever/chessever-frontend/blob/57ff22376a46777f83de238bdcc9502daf8c53c6/`.
- This change is a Desktop client policy implementation. Existing server entitlements, authentication, billing, and database APIs remain authoritative. No server deployment, migration, purchase, subscription mutation, cleanup job, or production-data operation was performed.
- User-directed Desktop exceptions: **the entire Prepare workstation is Premium**; **personal PGN opening/editing/saving/exporting and recovery of existing personal work stay free**. Do not silently copy phone overage read-locks onto personal Desktop documents.

## Reachable phone source, not similarly named leftovers

- Explorer is reached through `screens/home/home_screen.dart:162` and `screens/library/library_screen.dart:98`; profile Build Tree reaches its scoped variant at `screens/player_profile/player_profile_screen.dart:363–390`.
- Smart collections are reached from `screens/group_event/widget/all_events_tab_widget.dart:67`, `for_you_games_widget.dart:552`, and `screens/discover/discover_screen.dart:304`.
- Discover Miniatures is **also reachable**, via `screens/discover/discover_screen.dart:509`. It is not the same contract as the Premium smart-event game-open guard. Its first 12 visible games open freely.
- `screens/favorites/tabs/favorites_games_tab.dart:1502` has a stale comment mentioning a premium guard; the actual callback at `1540–1546` simply navigates. A comment is not an entitlement check.
- `LibraryFolder.isSubscribed` means following somebody's shared book, not holding ChessEver Premium. Do not confuse these concepts.

## Matrix

| Surface / action | Free | Premium trigger | Phone evidence | Desktop implementation |
|---|---|---|---|---|
| App entrance | Authenticated, non-anonymous users enter the shell | None; Premium is not an entrance condition | Phone feature-local guards rather than Desktop's legacy entrance barrier | `desktop/auth/desktop_auth_gate.dart`; mandatory updater remains around the shell |
| Events, calendar, standings, regular broadcast game viewing, YouTube | Existing functionality and ordinary controls | None | No subscription/`requirePremiumGuard` gate on the ordinary event-view route; compare explicit collection gates below | Shell routes, event navigation, updater, media pipeline remain unchanged |
| Ordinary board / engine / existing Game Report | Existing Desktop behavior, including personal edits and export | No additional report gate inferred | No reachable phone report-specific premium guard found in the inspected subscription/guard call graph | `desktop/panes/board_pane.dart` keeps the normal analysis path; report/engine services were not paywalled |
| Favorite players | Add up to **3**, remove freely; existing excess favorites are not deleted | Fourth new favorite | `utils/favorite_constants.dart:3`; `utils/favorite_limit_guard.dart:44–68`; `providers/favorite_players_provider.dart:168–172` | `desktop/auth/desktop_quota_guard.dart`, `desktop_favorite_quota_notifier.dart`; shared `utils/favorite_limit_guard.dart` dispatches Desktop first |
| Favorites games feed | Browse/open existing feed | No newly inferred game-open paywall | `screens/favorites/tabs/favorites_games_tab.dart:1540–1546`; stale comment explicitly rejected | Existing `favorites_pane.dart` path left free |
| Cloud saved games | **10 total rows across all databases**, not ten per folder | A new insert/bulk/import exceeding total 10 | `utils/library_utils.dart:11–13`; `utils/save_to_library_guard.dart:8–37` | `desktop_library_quota_repository.dart` wraps both single and bulk INSERT; `desktop_quota_guard.dart` supplies the forui admission UI; existing save dialog and quick import reuse it |
| Update an existing cloud game | Free, including when already above the cap | No new-slot charge for UPDATE | Phone save helper counts games **to add**, not existing edits | Inherited `updateSavedAnalysis`, save-dialog Update Original, and retention/export paths remain unrestricted |
| New cloud databases | **3 owned databases**; organizational folders are free | Fourth database | `utils/library_utils.dart:7–9`; `screens/library/library_screen.dart:209–220` counts `!isSubscribed && isDatabase`, excluding synthetic TWIC | `desktop_database_creation_guard.dart`, `desktop_library_quota_repository.dart`, Library and save-dialog create entry points |
| Cloud node identity | Existing account schema | Not a new entitlement | `repository/library/models/library_folder.dart:43,61,75,95–96`; `supabase/migrations/20260530004300_split_library_folders_and_databases_phone.sql:23–30` | New Desktop-created rows explicitly send existing `node_type: folder/database`; quota counts authoritative `node_type`, including legacy null-as-database compatibility |
| Cloud sorting | Browse/search/open/export personal saved work freely | Changing cloud table sort | `screens/library/folder_contents_screen.dart:77–87,193` gates filter/sort but explicitly leaves search free | Cloud saved-game sort callbacks in `desktop/panes/library_pane.dart`; local PGN sorting is a separate free path |
| Global opening explorer | Initial position through **19 played plies** | Position after ply 20, or a forward step crossing that boundary | `screens/gamebase/widgets/move_statistics_panel.dart:31,54–64`; `providers/gamebase_explorer_state.dart:150–152`; `gamebase_explorer_screen.dart:298–312,917–928,1940–1945,2034–2040` | `desktop_access_policy.dart`, `desktop_explorer_policy.dart`; standalone board moves, jumps, notation navigation, inline explorer, repository fetch/cache/prefetch boundary |
| Explorer off-by-one | `currentMoveNumber = playedPlies + 1`, limit `20` | Do **not** interpret the comment as allowing 20 completed plies | Phone comment at `move_statistics_panel.dart:28–30` conflicts with its actual executable boundary; the code above is the authority | Pure policy regression pins 19 allowed / 20 denied; ordinary board navigation itself is never stopped |
| Explorer player filter / scoped preparation | Other ordinary filters remain as before | Player-scoped query, player tree | `screens/gamebase/widgets/gamebase_filter_panel.dart:574–590`; `gamebase_explorer_screen.dart:1119–1120,1252–1255`; profile Build Tree `player_profile_screen.dart:363` | Desktop player-filter input gate and injected explorer notifier admission reject seeded/cached player queries too |
| Exact-position/FEN search | Basic board/FEN editing remains free | Remote exact-position database search | Desktop-only advanced-query policy, not a fabricated phone limit | `desktop_explorer_policy.dart` and both explorer hosts distinguish a noninitial FEN query from normal board editing |
| Explorer / system Gamebase games | Preview/browse metadata | Open, insert a remote continuation, full PGN export, save remote database game | `screens/gamebase/widgets/position_games_sheet.dart:591`; `screens/library/widgets/gamebase_search_game_card.dart:83,106`; `library_search_results_view.dart:604,644` | Position table, TWIC board-args factory, master-database copy/context-menu paths, common board admission, serialized detached payload |
| Generated smart collections (Live/GM/etc.) | Browse collection previews | Open collection game through any activation method | `screens/group_event/smart_event/smart_event_screen.dart:1747–1750` | `_openSmartGame`, `LiveDesktopGameCard` provenance, drag payload, context menu, new-tab/window open helper; same game opened from its regular broadcast remains free |
| Countrymen games | Browse | Open from Countrymen | `screens/countrymen/tabs/countrymen_games_tab.dart:862,922,1364` | Countrymen callbacks/card provenance and common `ChessboardView.countryman` admission |
| Discover Miniatures | Browse/open **first 12** current filtered entries; existing search/filter behavior retained | Full list beyond 12 | `screens/library/discovery/miniatures_tab.dart:48–68,123–153` | Desktop Miniatures visibly labels the free preview, limits its board rail to the visible range, suppresses further pagination, and offers full-list Premium CTA |
| Public player profile | Basic identity/rating/profile browsing remains distinct from Prepare | Opening profile games; combining **2+ active criteria**; bulk player-game operations | `player_profile/player_profile_screen.dart:248–263`; `tabs/player_games_tab.dart:410–415,1388–1400,1471–1483` | Common player-profile-source open gate; `desktop_player_profile_policy.dart` overrides all filter mutators, search/result counting, bulk paging and refresh; root shell coalesces paywalls |
| Prepare workstation | Discoverable, useful **labeled locked preview**; no fabricated stats | All real overview/stats/charts/accounts/games/tree UI; account/source lookup, import, sync, reinstall, combined-tree build, game opening | **Explicit user direction**, a Desktop-only paid workstation rather than a wholesale phone screen copy | Lazy `PlayerWorkspacePane` admission before any data child mounts; notifier operation guards; repository guards before HTTP stages and source-cache polls; Build Tree helpers recheck before opening |
| Personal local PGN / recovery | Open, edit, save, copy, export, sort; existing personal local database/tree work is not held hostage | Only the separate Prepare workflow and remote database facilities are gated | **Explicit user direction** overrides potential phone read-lock analogies | Local scanner, file mutation, cache writer queue, PGN persistence, local exports and personal cloud UPDATE/export are not disabled or deleted |
| Already admitted board on expiry | Private draft, analysis, save/export remain alive | New paid game/database/tree work requires current access again | User-directed retention invariant | `desktop_board_access_gate.dart` admits once per game lifetime; source provenance remains on args; new rail/card/open operations recheck live policy |
| Restore / purchase | Reuse existing cross-device membership | Existing subscription view, not a second Desktop entitlement | Existing server `entitlement` response / `public.subscriptions` mirror | Existing `DesktopSubscriptionView` used inside forui helper; no new billing API or autonomous purchase |

## Admission and lifecycle rules

1. **Unknown/loading** is checking, never an upsell or a Premium grant. A free-quota action can still proceed after a successful authoritative count proves it fits the free tier.
2. **Error/offline** denies new Premium work and offers Retry. No cached boolean is promoted to Premium. The offline cache remains only for recovery of an authenticated shell/personal work.
3. **Nonrenewing but active** remains Premium until expiration. At the exact expiration boundary, new paid actions stop and a backend refresh begins.
4. **Server-confirmed billing grace** is honored while `isActive` is true. `past_due` can outlive the ordinary term timestamp; it is not treated as ordinary expiration. An error/offline response does not extend this grace.
5. **Account changes** reset subscription state and increment the request generation. A late response from the old account cannot publish entitlement state. Request completion cannot clear a newer in-flight request, and disposal cancels polling/expiry timers.
6. **Routine refresh** does not unmount the whole shell or discard an admitted board. Prepare's admitted UI survives a routine refresh; repository continuations may finish against the still-valid previous entitlement. Fresh paid action admission remains strict.
7. **Expiry is not deletion.** No retention cleanup, PGN purge, cloud deletion, or favorite trimming was added. Atomic writes already admitted are allowed to finish; new stages/requests are checked before expensive work.
8. **Detached windows** serialize `requiresPremium`. Legacy continuation/source metadata also recovers admission intent when an older payload lacks the new field. Personal save origins and retained private drafts remain recovery exceptions. The receiver may create only a locked tab preview while its own entitlement is loading; this is not authorization to mount/hydrate the real board. Prepare tabs use the same lazy pane gate. The override set is installed in both main and detached process containers.
9. **Replay/input paths** include pointer activation, keyboard, modifier/new-tab, drag-to-tabs, context-menu window opens, retained rail navigation, seeded explorer positions and provider debounce/prefetch. User-owned basic file operations remain a distinct free path.

## Backend and verification limitations

- The quota guards serialize COUNT + INSERT within one process, including all library repository single/bulk writes. **They are not a server security boundary.** Separate devices/processes can still race; atomic cross-device quota enforcement requires a backend transaction/RPC or database policy owned by the backend team. No unsupported enforcement API is invented here.
- The `node_type` field is proven by the phone migration and current source contract; no production schema query or migration execution was performed during this work.
- The source audit is static. No phone runtime, Desktop runtime, screenshot, app build, billing transaction, or database mutation was used to validate it.
- Regression sources are authored and analyzed, **not executed**, following the repository/task's analyze-only verification instruction. Do not present them as passing runtime tests.
- Game Report is a documented no-new-gate decision, not a discovered phone report entitlement. Most Liked / dedicated phone My Likes surfaces are not newly ported by this change.
- Release readiness still requires human review and user-run runtime verification, especially free/premium account switching, short-window paywall layout, detached windows, offline retry, full-path quota interactions, and server quota-race behavior.

## Self-review checklist

- [x] Removed the entrance subscription check without altering ordinary event, media, settings or updater routing.
- [x] Used server subscription override rather than a debug Premium grant; Desktop dispatch happens before legacy phone debug bypasses.
- [x] Prepare data child is not instantiated in locked/loading/error states; public profile does not implicitly watch the preparation workspace for a label.
- [x] Preserved quota-free UPDATE/delete/export and local PGN ownership paths.
- [x] Audited actual phone ply boundary and reachable free Miniatures exception instead of copying labels/comments.
- [x] Propagated paid-source identity through board copies, rail replacements and detached payload encode/decode; normal broadcast identity stays free.
- [x] Added current-account/post-await checks around entitlement publication and quota admission; queued cloud writes release their successor even on failure.
- [x] No package, updater, native runner, engine binary, release pipeline, backend migration, secret, or production data change is included.
- [ ] Runtime verification: intentionally left to the user/reviewer; analyzer success is not a claim that the app was run.
- [ ] Atomic cross-device quota enforcement: backend follow-up, not claimed by this client PR.

## Candidate verification (20.32.14+363)

- Focused `flutter analyze --no-pub` covered **46 changed/new Dart source and regression files**.
- **0 errors, 0 warnings, 0 introduced diagnostics.** The command exits 1 because it reports **24 pre-existing informational deprecations**, independently reproduced against the untouched base (2 `cacheExtent`, 22 `withOpacity`). No analyzer rules were disabled.
- `git diff --check` passed. New policy/helpers and new regression sources were formatted; broad legacy-file formatting was deliberately avoided.
- Regression sources cover quota limits and queue failure release, exact ply boundary, unknown/expired/billing-grace transitions, cold loading vs admitted refresh, lazy Prepare admission, admitted-board retention, legacy payload admission and detached round trips. Existing paid-workspace/explorer fixtures now opt into Premium explicitly rather than relying on an app-wide grant.
- Tests/build/run were not executed. Production and the running Development artifact are unchanged.
- Publication preflight: fetched base still `e54f6884885069e3e3d641707cccf48735228303`; no base drift; zero open Desktop PRs/overlap; reviewer queue pause is false. This is a review candidate, not permission to merge or release.

## Explicit publication file inventory

```text
docs/desktop_freemium_matrix.md
lib/desktop/auth/desktop_access_policy.dart
lib/desktop/auth/desktop_auth_gate.dart
lib/desktop/auth/desktop_database_creation_guard.dart
lib/desktop/auth/desktop_explorer_policy.dart
lib/desktop/auth/desktop_favorite_quota_notifier.dart
lib/desktop/auth/desktop_library_quota_repository.dart
lib/desktop/auth/desktop_player_profile_policy.dart
lib/desktop/auth/desktop_quota_guard.dart
lib/desktop/auth/desktop_quota_queue.dart
lib/desktop/desktop_main.dart
lib/desktop/panes/board_pane.dart
lib/desktop/panes/countrymen_pane.dart
lib/desktop/panes/desktop_smart_games_pane.dart
lib/desktop/panes/library_pane.dart
lib/desktop/panes/opening_explorer_pane.dart
lib/desktop/panes/player_workspace_pane.dart
lib/desktop/services/desktop_board_window_payload.dart
lib/desktop/services/desktop_board_window_service.dart
lib/desktop/services/desktop_subscription_stub.dart
lib/desktop/services/player_workspace_repository.dart
lib/desktop/shell/desktop_shell.dart
lib/desktop/state/active_board_game.dart
lib/desktop/state/player_workspace.dart
lib/desktop/widgets/desktop_access_gate.dart
lib/desktop/widgets/desktop_board_access_gate.dart
lib/desktop/widgets/desktop_explorer_filters.dart
lib/desktop/widgets/desktop_opening_explorer.dart
lib/desktop/widgets/desktop_position_games_table.dart
lib/desktop/widgets/event_games_table.dart
lib/desktop/widgets/library/library_save_to_folder_dialog.dart
lib/desktop/widgets/notation_opening_panel.dart
lib/desktop/widgets/player_profile_view.dart
lib/desktop/widgets/tournament_games_view.dart
lib/screens/gamebase/providers/gamebase_providers.dart
lib/utils/favorite_limit_guard.dart
lib/utils/save_to_library_guard.dart
lib/widgets/paywall/premium_paywall_sheet.dart
pubspec.yaml
test/desktop/desktop_freemium_admission_test.dart
test/desktop/desktop_freemium_policy_test.dart
test/desktop/desktop_position_games_table_test.dart
test/desktop/notation_opening_panel_test.dart
test/desktop/player_delete_pane_heartbeat_test.dart
test/desktop/player_delete_responsiveness_test.dart
test/desktop/player_deletion_tombstone_test.dart
test/desktop/player_workspace_pane_test.dart
test/desktop/player_workspace_repository_test.dart
```
