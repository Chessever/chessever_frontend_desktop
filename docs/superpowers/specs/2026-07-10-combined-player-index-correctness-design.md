# Combined Player Index Correctness

## Goal

The Players Overview must treat Combined as a trustworthy, deduplicated source.
Selecting Combined with a time control must produce the same game population for
the headline count, W/D/L, ratings, charts, openings, opponents, years, and the
Games-tab handoff. Top Openings must show a real opening name whenever a valid
ECO code is available, even when the source PGN omits its optional `Opening`
header.

## Canonical game metadata

Each source passed into the Combined builder carries both its path and its
`PlayerWorkspaceSource`. Deduplication continues to use the original PGN
fingerprint, before any derived metadata is added.

For every retained game, the builder resolves:

- source: ChessEver, Lichess, Chess.com, or manual PGN;
- time-control category: explicit `TimeControl` first, then event/site
  heuristics, then the trusted source fallback;
- opening name: a meaningful PGN `Opening` value first, then the canonical name
  for a valid ECO code.

Only ChessEver has a trusted missing-clock fallback to Classical. Explicit
rapid, blitz, bullet, or classical metadata always wins. Untagged online and
manual games remain unclassified rather than being guessed.

The Combined PGN stores the resolved source and time-control category in custom
PGN tags. Custom tags keep the derived file portable and make a subsequent
local-cache import deterministic without opening or joining every source
database. They do not participate in deduplication.

## Versioning and refresh

The derived Combined PGN carries a format-version tag. A Combined file without
the current version is stale. When source files still exist, the workspace
rebuilds the stale file through the existing queued import path and updates the
player revision. This is a one-time repair for already-created player profiles.
It must not create a second SQLite writer or bypass the shared local-cache write
queue.

If a source file is missing, the last readable Combined database remains
available and the workspace reports the source error; it must not silently
delete valid cached games.

## Query consistency

`PlayerStatsRepository` continues to aggregate one Combined `database_id`, but
its canonical time-control expression reads the stored resolved category.
Every aggregate CTE uses that same scoped population. The Games-tab filter uses
the same category values, so Overview taps cannot disagree with the displayed
count.

Top Openings groups by normalized ECO code. It uses a meaningful stored opening
name when present and `EcoOpenings` as the fallback. Values such as empty text,
`?`, `Unknown`, and `Unknown opening` do not override a known ECO name. If an ECO
code is invalid or absent, the UI may still show Unknown; it must never show
Unknown for a code covered by the app's ECO catalog.

Opening enrichment is also applied while importing every individual local
source, not only while building Combined. Existing cache rows are repaired once
through a versioned schema migration. This keeps the Games table's displayed
opening, opening search, and opening-column sort identical for Combined and for
each individual source.

An unresolved time control is stored as the explicit `unknown` sentinel rather
than SQL `NULL`. This makes derived-filter repair converge and keeps unknown
games out of exact Classical, Rapid, Blitz, and Bullet selections unless a
trusted source rule classified them.

The Games query composes all filters before it applies sorting and pagination.
That contract covers filters handed off by Overview (result, color, ECO, year,
time control, and opponent), dialog-only filters (rating range, finish reason,
and online category), free-text search, every sortable table column, both sort
directions, and every page. Search terms are literal data: `%` and `_` must not
be interpreted as SQL wildcards.

## Verification

A mixed-source integration fixture will contain:

- untagged ChessEver classical games;
- explicitly rapid/blitz ChessEver games;
- explicitly classified Lichess and Chess.com games;
- an untagged manual game;
- a duplicate shared across two sources;
- games with valid ECO codes but no `Opening` header.

The regression must prove deduplicated totals, Classical scope, W/D/L, year
series, rating series, source breakdown, Top Openings names, and Games-filter
counts agree. A stale-version fixture must prove the derived file is detected
and rebuilt. Existing single-writer concurrency and first-open responsiveness
tests remain green.

An independent in-memory oracle exercises the cartesian product of representative
filter/search scenarios with every sortable column, both directions, and
multi-page results. It also compares every Overview handoff count with the
corresponding computed statistic. Separate cache tests prove that newly imported
and already-cached ECO rows receive canonical opening names, and that unknown
time-control repair reaches a stable state.
