# Player Combined Rebuild Hardening

## Goal

Make the Players workspace source rail present Combined before Manual PGN, and make the Combined database's deduplication and rebuild behavior demonstrably correct, responsive, and failure-safe for large player libraries.

## User experience

The source rail order is:

1. ChessEver
2. Lichess
3. Chess.com
4. Combined
5. Manual PGN

Combined remains a generated, read-only source. Its card exposes Rebuild Combined and displays live operation state while preparation and cache import are running. Manual PGN remains the final source card and retains its existing add/import behavior.

## Combined data contract

Rebuild Combined reads every connected source PGN for the selected player, including Manual PGN accounts. A game is unique by `localChessPgnFingerprint`, the same canonical identity used by the local chess importer. Therefore equivalent PGNs deduplicate across sources even when they differ only in header ordering, whitespace, comments, or equivalent SAN spelling.

The first occurrence in source-rail order wins when the same game appears in multiple sources. The emitted game retains that source's Combined provenance metadata. The output contains exactly one Combined version tag and one source tag per game.

The generated PGN is written to a temporary file and atomically replaces the prior Combined PGN only after preparation succeeds. A failed or cancelled rebuild must leave the last successful Combined database and persisted metadata usable.

## Responsiveness and progress

PGN scanning, fingerprinting, statistics, and output writing stay off the UI isolate. The worker reports meaningful preparation progress based on source-file work, followed by the existing local-cache import progress. The operation UI must continue repainting while a large cold rebuild runs and must never appear parked indefinitely at a fixed preparation percentage.

All local chess cache mutations continue through the existing shared repository connection and write queue. The implementation must not introduce another same-file SQLite writer.

## Verification

Regression coverage will prove:

- the rendered source ordering places Combined immediately before Manual PGN;
- equivalent copies of one game in different sources produce one Combined PGN game and one cached SQLite game;
- distinct games remain present and source provenance is deterministic;
- each emitted game has a single Combined version tag and source tag;
- the real cold rebuild path keeps the event loop responsive and reports advancing preparation/import progress;
- a preparation failure preserves the previous Combined file;
- `flutter analyze` is clean after the changes.

## Scope

This change does not alter source download APIs, player identity, updater behavior, unrelated local-library deletion work, or the public Players workspace model. It strengthens the existing streaming Combined builder rather than replacing it with a SQL-only union.
