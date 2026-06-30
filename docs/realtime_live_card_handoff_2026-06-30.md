# Realtime Live Card Handoff - 2026-06-30

## Situation

Community events such as Titled Tuesday can start the next round immediately after
the previous round finishes. The frontend must show each newly live game and every
move as soon as the `games` row changes in Supabase Realtime.

The current direction is not a revert to one channel per card and not a
round-wide/tour-wide card subscription. The frontend uses shared, scoped,
game-id batch subscriptions for list/card surfaces, while focused board screens
keep a single-game stream.

Current pushed baselines before this handoff doc:

- Desktop: `chessever_frontend_desktop` on `main`, `95d6d71b524927fb6e3a6c93c87b1e4e9d52950f`
- Mobile: `chessever-frontend` on `dev`, `5b2437aed236672e86efdf74044954f1d2ae09b3`

## Why This Direction

Supabase Realtime has per-connection channel limits. On desktop, a wide/tall
screen can mount dozens of game cards at once. A per-card channel model can be
low latency while under limits, but it fails hard once a client opens too many
channels or joins too quickly.

The intended compromise:

- Every live game row still updates independently.
- A visible context shares small `id IN (...)` Realtime streams instead of N
  isolated card streams.
- Riverpod `autoDispose` closes the stream provider when the last mounted card
  using that batch leaves the widget tree.
- Finished game cards do not open their own live stream.
- A board opened for a game keeps a focused single-game stream so
  `chess_board_screen_new.dart` and the desktop board pane always track the
  latest position for that one game.

## Core Invariants

Do not reintroduce hidden round/tour fallbacks for live cards.

Good:

- `LiveGamesBatchKey(scopeId: ..., gameIds: visibleOrContextIds)`
- `LiveDesktopGameCard(... liveBatchKey: explicitKey)` for known visible rails
- `LiveDesktopGameCard(... eventGames: contextGames)` or `routeGames:
  contextGames)` where the wrapper derives a chunk key
- `gameUpdatesStreamProvider(gameId)` for a focused board only

Bad:

- one `gameUpdatesStreamProvider(gameId)` per mounted game card in a list
- `LiveGamesBatchKey(... roundId: game.roundId)` as an implicit card fallback
- `LiveGamesBatchKey(... tourId: game.tourId)` as an implicit card fallback
- round-wide/tour-wide card streams for mixed event views
- pausing the mounted card's Supabase row updates during scroll

Scroll pause should only suppress expensive visual work such as Stockfish
fallback on cards. It must not freeze realtime PGN/FEN/clock/status row updates
for mounted live cards.

## Current Implementation Map

### Shared stream providers

File: `lib/screens/chessboard/provider/game_pgn_stream_provider.dart`

- `gameUpdatesStreamProvider(gameId)` is an `AutoDisposeStreamProvider.family`
  for focused board views.
- `liveGameUpdateStreamProvider(gameId)` is the typed single-game provider.
- `gameUpdatesStreamProvider(gameId)` re-emits `liveGameUpdateStreamProvider`
  so a board and any single-game consumer share one Riverpod family instance.
- `LiveGamesBatchKey` equality is based on `scopeId`, optional round/tour, and
  sorted `gameIds`.
- `liveBatchKeysForGames(...)` is the shared helper for card/table surfaces:
  it filters to streamable live Supabase games and returns 25-game chunk keys.
- `gameUpdatesBatchStreamProvider(batchKey)` subscribes to:
  - round only if `roundId` is explicitly set
  - tour only if `tourId` is explicitly set
  - otherwise `subscribeToLiveGameUpdatesBatch(key.gameIds)`

The current card paths should produce only game-id batch keys, not implicit
round/tour keys.

### Live card merge/provider

File:
`lib/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart`

- `kLiveContextBatchSize = 25`
- `liveContextBatchKeyForGame(...)` finds the game inside the provided context
  list and chunks that context into 25-game batch keys.
- `shouldSubscribeToLiveGame(game)` requires:
  - `game.source == GameSource.supabase`
  - non-empty `game.gameId`
  - `!game.gameStatus.isFinished`
- `_liveWatchParamsForGame(...)` disables streaming if the base game is finished
  or no explicit/context batch key exists.
- `_watchLiveUpdate(...)` uses `gameUpdatesBatchStreamProvider(batchKey)` and
  `select(...)` to project only the update for the current game and merge mode,
  limiting rebuilds from unrelated games in the same batch.
- `mergeLiveGameUpdateWithBase(...)` and `shouldReplaceBaseGame(...)` prevent
  stale REST snapshots from overwriting fresher realtime PGN/FEN/clock/status.

### Desktop card entry point

File: `lib/desktop/widgets/tournament_games_view.dart`

`LiveDesktopGameCard` is the central desktop card wrapper. It computes:

```dart
final effectiveLiveBatchKey =
    liveBatchKey ??
    liveContextBatchKeyForGame(
      game: game,
      contextGames: eventGames.isNotEmpty ? eventGames : routeGames,
      scopePrefix: 'desktop_context',
    );
```

Then it calls:

```dart
watchLiveGame(ref, game, batchKey: effectiveLiveBatchKey, ...)
```

This is the path desktop tournament cards, smart-game cards, countrymen cards,
favorites cards, player profile cards, and For You cards should use.

## Desktop Live Smart Event Audit

File: `lib/desktop/panes/desktop_smart_games_pane.dart`

The desktop home "Live" smart collection is `PremiumGamesType.live`. It is
loaded through `premiumGamesProvider(type)`, filtered through
`visibleDesktopSmartGames(...)`, then rendered by `_SmartGamesList`.

The grid and flow card layouts already use the shared card mechanism:

- grid card call: `LiveDesktopGameCard(... routeGames: groupedGames, ...)`
- flow card call: `LiveDesktopGameCard(... routeGames: groupedGames, ...)`

Because `routeGames` is passed, `LiveDesktopGameCard` derives the same
25-game context batch mechanism used elsewhere. On a screen mounting 60-80 live
cards, this should be a few chunk streams rather than 60-80 channels.

Important nuance: the smart-pane `groupedGames` context is the filtered smart
collection grouped by sections, not strictly "current viewport only." This is
still bounded by 25 IDs per mounted chunk and avoids per-card channels. If a
follow-up agent makes this stricter, keep `routeGames` unchanged for board
navigation and pass a separate explicit `liveBatchKey` built from the currently
rendered section/viewport IDs. Do not sacrifice board navigation context to save
channels.

The smart-pane table/list layout uses `_SmartGamesTableRow`, not
`LiveDesktopGameCard`. It now watches lightweight table-level
`gameUpdatesBatchStreamProvider(...)` chunks and merges each row before
render/open. Do not add per-row single-game streams here.

## Other Desktop Surfaces Checked

The main desktop card surfaces route through `LiveDesktopGameCard`:

- Tournament/event game cards:
  `lib/desktop/widgets/tournament_games_view.dart`
- Desktop home smart collections, including "Live":
  `lib/desktop/panes/desktop_smart_games_pane.dart`
- Desktop For You event panels:
  `lib/desktop/panes/tournaments_pane.dart`
- Event board side rail:
  `lib/desktop/widgets/event_games_table.dart`
- Favorites:
  `lib/desktop/panes/favorites_pane.dart`
- Countrymen:
  `lib/desktop/panes/countrymen_pane.dart`
- Player profile game cards:
  `lib/desktop/widgets/player_profile_view.dart`
- Player profile table rows:
  `lib/desktop/widgets/default_games_table.dart`

The event board side rail uses explicit visible-game chunk keys:

```dart
LiveGamesBatchKey(
  scopeId: 'desktop-event-rail:$activeTabId:${kind.index}:$chunkIndex:...',
  gameIds: liveVisibleGamesInChunk.map((game) => game.id),
)
```

It returns no keys for database rows, empty lists, and finished-only lists.

Desktop For You uses explicit visible-game keys:

```dart
LiveGamesBatchKey(
  scopeId: 'desktop_for_you:$eventId:$tourId',
  gameIds: games.map((game) => game.gameId),
)
```

## Board / Latest Position Contract

Do not batch focused board streams. The open board should stay on the
single-game provider.

Desktop board:

- `lib/desktop/panes/board_pane.dart`
- listens to `gameUpdatesStreamProvider(activeGameId)` only for the foreground
  board tab
- calls `syncLiveGameRowWithDesktopSurfaces(...)`
- merges realtime rows via `mergeLiveGameUpdateWithBase(...)`
- writes to `baseGameProvider(gameId)` only when `shouldReplaceBaseGame(...)`
  says the incoming snapshot is not stale
- applies PGN incrementally when possible and falls back to full PGN parse

Shared board provider:

- `lib/screens/chessboard/provider/chess_board_screen_provider_new.dart`
- listens to `gameUpdatesStreamProvider(game.gameId)` for ongoing games
- seeds from the cached stream value immediately when available

Mobile board screen:

- `projects/chessever-frontend/lib/screens/chessboard/chess_board_screen_new.dart`
- on lifecycle resume invalidates:
  - `gameUpdatesStreamProvider`
  - `liveGameUpdateStreamProvider`
  - `gameUpdatesBatchStreamProvider`

This keeps reopened boards/cards from using stale provider instances after app
resume.

## Supabase / Performance Notes

This frontend design reduces channel pressure, but it does not remove the need
to monitor Supabase Realtime limits. If users report delay while worker logs show
fresh row writes, check Supabase Realtime logs for:

- `too_many_channels`
- `too_many_joins`
- `tenant_events`
- disconnect/reconnect churn

Dashboard plan increases may be needed only if production usage truly exceeds
message/connection/join limits after this client-side channel reduction. Do not
paper over a frontend channel leak with dashboard limits.

Expected frontend channel shape:

- open board: one single-game stream
- visible card context: one stream per 25-game chunk currently observed by
  mounted cards
- finished card: no card-owned stream
- static/non-live/database cards: no live stream

Every individual game row still receives its own realtime update from Supabase.
The batch stream is only a transport/channel sharing mechanism.

## Validation Already Run

Mobile after the realtime changes:

```bash
flutter analyze --no-pub lib/providers/for_you_games_provider.dart lib/screens/group_event/widget/for_you_games_widget.dart lib/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart lib/screens/tour_detail/games_tour/widgets/games_list_view.dart lib/screens/tour_detail/games_tour/widgets/group_event_match_card.dart test/live_game_card_provider_test.dart
flutter test --no-pub test/live_game_card_provider_test.dart test/for_you_games_provider_test.dart
flutter test --no-pub test/live_game_position_resolver_test.dart test/chess_board_live_fen_placeholder_test.dart
```

Desktop after the realtime changes:

```bash
flutter analyze --no-pub lib/providers/for_you_games_provider.dart lib/screens/group_event/widget/for_you_games_widget.dart lib/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart lib/desktop/widgets/event_games_table.dart lib/desktop/panes/tournaments_pane.dart test/live_game_card_provider_test.dart test/desktop/event_games_table_test.dart
flutter test --no-pub test/live_game_card_provider_test.dart test/for_you_games_provider_test.dart
flutter test --no-pub test/desktop/event_games_table_test.dart --plain-name 'event rail uses shown game ids for realtime tournament rows'
flutter test --no-pub test/chess_board_live_fen_placeholder_test.dart test/pgn_clock_parsing_test.dart
```

Known unrelated desktop issue:

- Full `test/desktop/event_games_table_test.dart` has a standalone failure in
  "Shift click ranges from the active event game across rounds" around line 985.
  The realtime-specific event rail test passes.

## Follow-up Audit Checklist

Use these searches before changing anything:

```bash
rg -n "LiveDesktopGameCard\\(" lib/desktop lib/screens
rg -n "gameUpdatesStreamProvider\\(" lib/desktop lib/screens
rg -n "LiveGamesBatchKey\\(" lib/desktop lib/screens
rg -n "implicit_round|implicit_tour|roundId: game.roundId|tourId: game.tourId" lib test
```

For every card/list surface:

- If it renders live board cards, it should go through `LiveDesktopGameCard`.
- If it renders many rows/cards, it must use a shared `LiveGamesBatchKey`.
- If it is a static table, do not add per-row single-game streams.
- If it is a focused board, keep `gameUpdatesStreamProvider(gameId)`.
- If it contains mixed live and finished games, only live Supabase games should
  stream; finished games must remain display-only.
- If changing scroll behavior, do not stop row updates for mounted live cards.

Manual runtime checks worth doing:

- Desktop home "Live" smart collection on a wide display with 60-80 cards.
- Desktop event view "Games" tab, including grid/flow/list layouts.
- Desktop event board side rail while a live board is open.
- Desktop For You event strip/panel.
- Desktop Favorites and Countrymen.
- Mobile event game card and opened `chess_board_screen_new.dart`.
- Round transition where the previous round finishes and the next starts within
  seconds.

The desired result is simple: when Lichess/worker writes a new PGN/FEN/clock row
to Supabase, every mounted card for that game and the opened board for that game
should show the same latest position without waiting for cyclic backfill.
