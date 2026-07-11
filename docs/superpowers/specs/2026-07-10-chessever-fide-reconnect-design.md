# ChessEver FIDE Reconnect and Manual Online Players

## Goal

Reconnecting the ChessEver source must not ask the user to search for a player
when the selected Players workspace already has a locked FIDE ID. The app must
resolve the one permitted ChessEver identity by exact FIDE ID, reconnect it,
and immediately download its games.

Players without a FIDE ID remain fully supported. The initial Add Player flow
must always expose a clear manual-player action so a user can create an amateur
or otherwise unindexed opponent and later connect that person's Lichess or
Chess.com usernames.

## Current behavior

Removing a ChessEver account deletes its generated data and clears the stored
ChessEver account/player ID, but deliberately preserves the workspace FIDE ID.
The reconnect UI nevertheless opens the generic player-name search dialog.
That search is redundant because the workspace rejects every ChessEver result
whose FIDE ID differs from the locked value.

The backend already accepts an exact `fideId` player query. The reconnect flow
does not need to retain a possibly stale ChessEver internal ID or ask the user
to choose an identity again.

## Reconnect behavior

The Players state layer owns a single exact-FIDE reconnect operation:

1. Read and normalize the selected player's locked FIDE ID.
2. Query ChessEver players by that exact FIDE ID.
3. Discard any response whose normalized FIDE ID does not exactly match.
4. Connect the matching ChessEver profile to the existing workspace.
5. Immediately run the normal ChessEver sync/download pipeline.
6. Import the generated source through the existing serialized local-cache
   writer and rebuild Combined through the existing path.

The UI chooses the flow from workspace identity:

- valid locked FIDE ID: execute exact-FIDE reconnect directly, without opening
  the ChessEver search dialog;
- no FIDE ID: keep the existing searchable ChessEver connection dialog.

The exact-FIDE lookup is authoritative. The implementation must not keep the
deleted ChessEver internal ID merely to bypass lookup because ChessEver records
can be reindexed while the FIDE ID remains stable.

If no exact match is returned, the source remains disconnected and the UI
shows a concise error. If profile connection succeeds but downloading fails,
the normal connected-account error/retry behavior remains available.

## Manual online players

The initial Add Player dialog keeps a permanently visible, explicitly labeled
manual-player action independent of ChessEver search results. A name is still
required to create the workspace. The user can then connect one or more
Lichess or Chess.com usernames through the existing account flow.

The absence of a FIDE ID must never reduce local-database functionality after
games are downloaded. A manual online player must support the same player-name
alias matching and local cache pipeline as other players, including:

- Overview statistics;
- Games-tab search, filters, and column sorting;
- local database indexing and searchable game metadata;
- opening-tree construction;
- source and Combined databases in the player's Library folder.

This change does not invent a synthetic FIDE ID and does not weaken the exact
FIDE identity guard for FIDE-backed workspaces.

## Boundaries

The repository/service layer provides an exact-FIDE ChessEver lookup seam. The
Players notifier coordinates lookup, connection, and sync so every UI entry
point receives identical behavior. The pane only decides between automatic
locked-FIDE reconnect and the existing no-FIDE search dialog, then presents
errors through existing desktop feedback patterns.

No new local chess database handle or writer is introduced. Downloads,
imports, Combined rebuilds, Library registration, filtering, indexing, and tree
building continue through their existing repositories and shared write queue.

## Verification

Regression coverage must prove:

- after removing ChessEver from a FIDE-locked workspace, reconnect queries the
  exact FIDE ID, opens no name-search dialog, reconnects the exact profile, and
  immediately downloads games;
- a mismatched or missing ChessEver response cannot connect another player;
- a no-FIDE workspace still opens the ChessEver search dialog;
- the initial Add Player flow always shows the manual-player action;
- a manually created no-FIDE player can connect an online username, download
  games, produce correct source/Combined stats, and expose data usable by the
  existing Games filters/index and opening-tree pipeline;
- relevant Players notifier and pane tests pass;
- targeted `flutter analyze` is clean.

Per repository policy, validation does not run `flutter build` or
`flutter run`.
