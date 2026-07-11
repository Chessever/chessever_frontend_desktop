# Two-phase player deletion design

## Problem

Removing a Players entry owns more than one row. A player folder can contain
ChessEver, Lichess, Chess.com, manual, and Combined PGNs, while the shared local
chess cache can hold games, analysis, position references, and opening-tree rows
for every generated source.

The current visible action removes the player from state, cancels operations,
waits up to eight seconds, and then immediately deletes files and physically
purges every cache row. The timeout allows cleanup to race an import that has
not stopped yet. Production Sentry hangs show HTTPS response parsing alongside
an active `resqlite` `sqlite3_step`, and the matching Windows session shows the
inactive/resumed sequence reported by the affected user before a later native
teardown crash. Memory and thermals are normal.

## Goals

- The trash action removes the row and selection immediately and silently.
- Downloads, imports, Combined rebuilds, and tree builds cannot write after the
  player has been deleted.
- Physical cleanup never races an active player-owned operation.
- A restart cannot resurrect the player or lose unfinished cleanup work.
- Every owned source, derived tree, analysis row, generated file, and the player
  folder is eventually deleted.
- Players remains responsive while cleanup runs; long database steps become
  identifiable in Sentry without recording usernames, PGNs, or local paths.

## Non-goals

- Changing normal Library deletion semantics.
- Exposing cleanup progress or a trash-management UI.
- Purging unrelated local metadata as part of a player deletion.

## Approved approach

### Phase 1: logical deletion

`removePlayer` captures the player's generated paths, adds the full player
record to a persisted pending-deletion collection, cancels every operation
scope owned by that player, clears queued Combined work, removes the player
from visible state, clears selection when needed, and persists the snapshot.
The dialog is then free to close. It does not wait for network, filesystem, or
SQLite work.

All source-sync/import/rebuild completion paths continue checking the deleted
player guard before updating state. Persisting the pending deletion extends
that guard across restarts and prevents late operation results from resurrecting
the player.

### Phase 2: serialized physical cleanup

A single player-cleanup queue handles pending records in order. For an in-session
deletion it waits for every captured operation scope to finish with no timeout.
The UI never awaits this wait. On restart there are no surviving operation
scopes, so persisted cleanup resumes directly.

Only after writers have released their handles does cleanup:

1. unregister every player-owned generated database;
2. mark all matching local-cache database records deleted through the existing
   shared local-cache write queue;
3. delete generated source files and the player workspace folder;
4. physically purge the tombstoned cache in small serialized batches without
   orphan-metadata or checkpoint work; and
5. remove the pending-deletion record only after cleanup succeeds.

Failures remain silent to the user. The pending record stays persisted and is
retried on the next load. A newly created player with a different id cannot be
affected by an old cleanup record.

### Responsiveness hardening

Player cleanup uses a small batch size and never performs row-count scans solely
to calculate unused progress. Replacement imports use the same cooperative
purge primitives. The shared write queue remains the only writer-serialization
boundary for the local chess cache.

The cache purge records table name, batch size, affected-row count, and elapsed
milliseconds for slow steps. Player deletion records stage transitions, source
count, active-operation count, and elapsed time. Diagnostics must not contain a
username, PGN content, FIDE id, source path, or player display name.

## Data model and compatibility

`PlayerWorkspaceSnapshot` gains an optional `pendingDeletions` list containing
serialized `PlayerWorkspacePlayer` records. Older snapshots decode it as empty.
Path normalization applies to active and pending players so cleanup still works
after the application-support root changes. Every snapshot write includes the
current pending collection and is serialized to prevent concurrent writes from
dropping a tombstone.

## Tests

- Snapshot JSON round-trip and old-snapshot compatibility.
- Removing a player persists a tombstone before returning and clears visible
  state immediately.
- Active Chess.com import cancellation must fully drain before files/cache are
  physically deleted; no eight-second timeout race is allowed.
- A late canceled import cannot restore a deleted player.
- Restart loads no deleted player and resumes pending cleanup.
- Failed cleanup retains its pending record for retry.
- Exact trash-button widget test covers inactive/resumed lifecycle, active
  Chess.com import, every generated source, selection/list rebuild, and at least
  production-scale tree cardinality.
- Heartbeat assertions reject sustained event-loop gaps and cache tests verify
  every player-owned row and folder is eventually removed.

## Release gate

Linux remains untriggered until the fix passes focused tests and analysis. The
next patch release is triggered and verified strictly in this order: Windows,
then macOS, then Linux. Each platform must publish successfully and appear in
the live updater feed before the next workflow starts.
