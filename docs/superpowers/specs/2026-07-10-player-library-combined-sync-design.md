# Player and Library Combined Synchronization

## Goal

Players and Library must present one authoritative Combined database for each
player. Its Library card count must equal the player-scoped Combined count in
Players, and the Combined card must always be the first database inside the
player's Library folder.

For the reported Vasif Durarbayli state, the complete Combined database
contains all Chess.com, Lichess, and ChessEver sources. Players reports 20,226
player-scoped games, while stale persisted Players and Library metadata reports
9,998. The implementation must repair that existing state automatically.

## Root cause

The Combined PGN and local Combined cache are complete. Their provenance rows
contain 10,573 Chess.com games, 6,016 Lichess games, and 3,982 ChessEver games.

Combined metadata is currently calculated from the union of individual source
database caches. Those caches are independently loaded and may be absent. At
the reported rebuild, only ChessEver and Lichess were available to the stats
query, so the stored result was exactly 3,982 + 6,016 = 9,998 even though the
freshly imported Combined database already contained every source.

Library then correctly persisted the incorrect Players value. Its timestamp
matches the Combined build timestamp, ruling out a stale Library-only card for
this incident. Separately, player-folder entries are sorted alphabetically and
do not persist their source identity, which places Combined after Chess.com and
ChessEver.

## Authoritative count

The freshly imported Combined database is the authority for Combined result
statistics. Rebuild and startup repair both query that one Combined path with
the same aliases, FIDE identity, deduplication, and result rules used by the
Players Overview. Library receives the repaired `combinedGameCount` from the
workspace model; it does not independently count PGN rows during rendering.

The physical file row count is not the displayed contract. The Library card
must show the same player-scoped count as Players—20,226 in the reported
fixture—not the physical 20,571 PGN rows and not the partial 9,998 source-cache
union.

If the Combined file or cache is temporarily unavailable, repair preserves the
last readable count. It must never replace it with a partial source-cache sum
or zero.

## Synchronization

Every Combined rebuild performs these steps in order:

1. combine and deduplicate source PGNs;
2. import the Combined path through the existing serialized local-cache write
   queue;
3. calculate player-scoped statistics directly from that imported path;
4. persist the updated player snapshot;
5. await Library registry metadata synchronization.

Startup repair runs the same direct Combined-path statistics query before it
registers player databases. A repaired count is persisted to both Players and
Library in that load cycle.

Registry mutations wait for initial registry hydration to finish. This prevents
a late hydration result from overwriting newer player metadata. Registry work
does not open another local chess database writer and does not bypass the
shared local-cache write queue.

## Source identity and ordering

Players-generated Library metadata persists the workspace source key for every
entry: `combined`, `chessever`, `lichess`, `chesscom`, or `manual`. The value is
JSON-backward-compatible and survives registry updates and round trips.

Inside a Players-generated Library folder, entries sort as follows:

1. Combined;
2. all other source databases in stable case-insensitive display-name order.

This priority applies only inside player folders. Other Library ordering is
unchanged. Legacy entries without a stored source key infer Combined from the
canonical Combined filename/path, so existing folders reorder immediately;
the next Players synchronization persists the explicit key.

## Verification

Regression coverage must prove:

- a partial source-cache union of 9,998 cannot override a complete Combined
  player count of 20,226;
- rebuild returns direct Combined-path statistics and persists them to Players
  plus Library;
- startup repair changes both stale Players and Library metadata to 20,226;
- a late registry hydration cannot overwrite a newer synchronized count;
- source identity survives JSON serialization and metadata updates;
- legacy and current Combined entries sort first inside player folders;
- remaining player sources retain stable alphabetical ordering;
- Combined PGN creation/import continues through the existing local-cache
  writer queue;
- relevant Players, Library registry, and ordering tests pass, and changed
  files pass targeted `flutter analyze`.

Per repository policy, validation does not run `flutter build` or
`flutter run`.
