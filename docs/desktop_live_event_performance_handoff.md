# Desktop live-event performance — handoff

**Status: unfinished work, handed over as a DRAFT PR. Not merge-ready.**

Nothing here is merged or released: this branch is a draft for continuation, not a
finished change. The performance work below was measured on an instrumented DEBUG
build of a throwaway copy of this worktree, on Windows, scrolled by an in-app
driver. It was **not** measured on a release build and **not** under real mouse
input. Section 3 lists exactly what is missing; read it before trusting section 2.

The work covers the two live surfaces that were rebuilt continuously:

| Surface | File |
|---|---|
| Board-view event rail (round-grouped board rows) | `lib/desktop/widgets/event_games_table.dart` |
| Tournament Games card grid + its cards | `lib/desktop/widgets/tournament_games_view.dart` |
| Card eval/evaluation read path | `lib/screens/chessboard/provider/current_eval_provider.dart` |
| Per-card live (Realtime) watch | `lib/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart` |
| Standings rows (keyed) | `lib/desktop/widgets/tournament_standings_view.dart` |

Two rounds of work are folded into this PR:

* **Round 1** — rail entry reuse, card-subtree memoization, per-card
  `RepaintBoundary`, the scroll-time eval gate, and the select-scoped live watch.
  This is the round with live before/after numbers (section 2).
* **Round 2** — element identity for the card grid: the key moved onto the
  delegate's own child plus `findChildIndexCallback`, and per-group sliver keys.
  **This round has no live after-measurement** (section 3, item 1); its proof is a
  deterministic widget-level element-survival test.

## 1. What the work is

### 1a. Board-view event rail — re-built and re-measured on every refresh and scroll

Problem: the rail's round-grouped list built its children as a plain
`List<Widget>` on every rebuild, so every mounted row chunk was reconstructed.
Each chunk is an intrinsic-width `Table`: rebuilding one dirties its layout and
re-measures every cell in it. Three more effects followed from the same design:

* the rail `ListView`'s key is the streamed/non-streamed identity flag, so a
  stream identity flip (window minimised/restored, Board tab hidden or
  foregrounded) built a fresh `ScrollPosition` at offset 0 — a reader on board
  300 of a long round was thrown back to the top. A controller only restores an
  offset through `PageStorage`, which needs a `PageStorageKey` this list
  deliberately does not have;
* the 1 Hz clock digits repainted their whole row;
* standings rows had no per-player identity, so a refresh rebuilt from the first
  changed row down.

Fix (`event_games_table.dart`):

* a **content-signature entry cache** (`_railEntryCache`, `_RailEntry`,
  `_RailChunkSignature`): while an entry's content signature matches, the builder
  hands back the *same widget instance*, and `Element.updateChild` short-circuits
  on an identical widget — nothing is rebuilt and no intrinsic measurement is
  re-run. Entries whose round is gone drop out of the cache
  (`_railEntryCache.removeWhere(...)`);
* **lazy, content-keyed entries** — `rail-header-<round>`,
  `rail-chunk-<round>-<start>`, `rail-gap-<round>`, `rail-label-<round>-<index>`,
  `rail-pagination`, `rail-loading` — so a rebuild constructs only the rows the
  viewport mounts (`eventRailEntryBuilds` counts constructed entries for tests);
* **invoke-time inputs**: cached row callbacks read the current build's games,
  args, title, kind and live batch keys through `_railLatest*` fields instead of
  closing over them (the Flutter counterpart of the web rail's
  `onSelectRef.current = onSelect`, `RoundGamesList.tsx:403`);
* **scroll-offset carry-over across the stream-identity flip**
  (`_preserveRailScrollAcrossIdentityFlip`): capture the outgoing offset while
  the old list is still attached, restore it once the replacement viewport
  exists, and only when the new list really reset; a generation counter makes a
  superseded restore a no-op;
* **`RepaintBoundary` around the live clock slot** in `_EventGamePlayerLine`
  (Flutter's primitive for the web's `contain: layout paint` on `.ce-cell`), so
  the 1 Hz digit repaints its own slot instead of the row chunk behind it;
* **keyed standings rows**: `ValueKey('event-standing-<fideId|name>')`
  (`tournament_standings_view.dart`), mirroring `key={row.playerId}`.

Tests added: `test/desktop/event_rail_row_reuse_test.dart` — an unchanged rail
rebuild reuses every mounted row chunk; a changed row invalidates its own chunk
and nothing else; every entry carries one stable content key; off-screen entries
are never constructed; a streaming identity change keeps the reader's position.

### 1b. Tournament Games card grid — card elements destroyed and re-created on every polled refresh

Problem, round 1: every polled refresh rebuilt each mounted card's subtree
(~520 cards/s during a Round-4 scroll), every mounted card ran its own
Gamebase/engine lookup for boards that were about to leave the viewport, and
each card subscribed to the whole round's Realtime batch, so one board's tick
rebuilt every other mounted card.

Fix, round 1:

* the card subtree is **content-memoized** (`_LiveCardMemo` + `_liveCardSignature`
  in `tournament_games_view.dart`): while the values the card actually renders
  are unchanged, the same instance is handed back;
* **`RepaintBoundary` per card**;
* a **scroll-time eval gate** (`gameCardEvalScrollGate` in
  `current_eval_provider.dart`, set by `_markLiveCardsScrolling` /
  `_markLiveCardsIdle` in `tournament_games_view.dart`): while the surface is
  scrolling, a card whose evaluation is not in the local cache returns without
  fanning out to Gamebase/engine;
* **per-card eval tracing made opt-in** (`CHESSEVER_EVAL_TRACE`): the
  unconditional "GAMEBASE MISS" `debugPrint` was producing more than 1,300
  synchronous console writes per minute during a scroll;
* **a select-scoped live watch per card**
  (`live_game_card_provider.dart`): `ref.watch(provider.select(liveGameCardContentKey))`
  plus `ref.read(provider)` instead of watching the raw value, so a Realtime tick
  for another board in the same scoped batch no longer rebuilds this card.

Problem, round 2: the grid's sliver children had no identity that survives
reordering. The card key sat on an *inner* widget and the delegate had no
`findChildIndexCallback`, and the re-published round changes game order and
team-group order on every refresh (measured: both order signatures changed once
per round build, ~4/s). A refresh therefore destroyed and re-inflated every card
element, and with it every card's Realtime subscription.

Fix, round 2:

* the card key moved onto the **delegate's own child** (the `RepaintBoundary`
  wrapped by the builder) with a `findChildIndexCallback` that maps the key back
  to its current index, so a reordered round *moves* card elements;
* **per-group sliver keys** on the team-match header/grid pairs and a per-round
  key on the plain round grid, so a structural change moves slivers instead of
  rebuilding the wall's unkeyed run.

Tests added: the `a reordered round moves mounted cards instead of remounting
them` case in `test/desktop/tournament_games_view_performance_test.dart`
(12 cards, full reorder, element identity compared per game id).

## 2. What works — measured numbers

All figures: instrumented DEBUG build (Windows) of a shadow copy of this
worktree, driven by an in-app `ScrollController` driver (4 `animateTo` phases
across up to 8,100 px of scroll extent, 6 s settle between phases), frames
captured with `WidgetsBinding.instance.addTimingsCallback`, analysed by
`analyze_frames.py` over the wall-clock window between the driver's
`autoscroll.start` and `autoscroll.done` events. **Not a release build, not real
input.** Logs and exact windows: section 4.

### Round 1 — card-grid scroll (tournament Games wall)

| Metric (in the scroll window) | Before | After, run 1 | After, run 2 |
|---|---|---|---|
| Frames produced | **9.9 fps** | **18.0 fps** | **18.9 fps** |
| Build p50 | **42.19 ms** | **18.36 ms** | **20.45 ms** |
| Build p90 | **81.94 ms** | **32.79 ms** | **34.00 ms** |
| Frames > 33.3 ms | **88.5 %** (524/592) | **30.9 %** (183/593) | **38.3 %** (233/608) |
| Frames > 16.6 ms | 89.5 % | 88.7 % | 89.5 % |
| Window length for the same driver script | 60.1 s | 33.0 s | 32.2 s |

The round's own notes recorded the same change as 9.8 → ~18 fps, build p50
42.2 → 18.4 ms, p90 81.9 → 32.8 ms, frames > 33 ms 89 % → 31 % — i.e. the run-1
column. Both after-runs are listed so the spread is visible; they are two
separate runs taken a few minutes apart (the measurement tree was re-synced
between them), not repeats of one build.

### Round 1 — evaluation I/O during the same scroll

Shadow-only counters either side of the gate (`eval.scroll_gamebase_lookup` /
`eval.scroll_gated`):

* before: **1,333** Gamebase eval lookups in the scroll session (the round's
  notes read 1,306 at scroll end);
* after run 1: **1,290 suppressed, 24 lookups** — effectively zero;
* after run 2: **1,341 suppressed, 1,082 lookups** — so the gate is not
  uniformly effective; the honest summary is "the gate suppresses the great
  majority of lookups while scrolling", not "lookups go to zero".

### Round 2 — element survival (this is the proof for round 2, not an fps number)

Deterministic widget-level test, run in the instrumented shadow tree against the
same source:

* before the fix: **0/12** mounted card elements preserved across a full round
  reorder (`Expected: <12>` / `Actual: <0>`);
* after the fix: **12/12** preserved (`All tests passed`).

Supporting counters from the round-2 pre-fix counter run (89 s session):
**16,918** card builds, **6,246** card mounts, **11,613** live-provider
re-creations — cards were being destroyed and re-created, not merely rebuilt.

### The rail surface, for scale

One rail scroll measurement exists (17.1 s window): **48.5 fps** produced, build
p50 **2.95 ms**, 7.2 % of frames over 33.3 ms — i.e. the rail was already the
cheaper surface. Note this run was taken with the rail fix **already in the
tree** (the fix reached the canonical worktree before the measurement tree was
cut), so it is not a rail before/after pair: the rail round's proof is the
widget-level row-reuse test plus the `eventRailEntryBuilds` entry counter, not
an fps delta.

## 3. What does not work / is unverified (blunt)

1. **Round 2 has no live after-measurement.** The measurement instance consumed
   the shared Supabase refresh session token and the run went into an error loop
   (`refresh_token_already_used`, `AuthApiException`), so the fixed-build scroll
   never started (its log has no `autoscroll.*` events at all). The
   element-survival test — not a live number — is the proof for round 2. A
   before/after mount-counter A/B was attempted twice and both fixed-build runs
   failed the same way.
2. **~89 % of frames still exceeded 16.6 ms after round 1.** The wall is still
   not a smooth surface; the remaining work is the windowing/streaming scoping
   below, not micro-optimisation.
3. **The outer card widget still rebuilds once per mounted card per refresh.**
   The web memoizes the row component itself (`RoundGameRow.tsx:294-312`); here
   only the inner card subtree is memoized (`_LiveCardMemo`).
4. **No visible-window report** from the wall to scope live subscriptions and
   evaluation targets, so live work is still driven by full re-publication of the
   round (web: `RoundBoards.tsx:1140-1157`, `useRoundData.ts:241-254`,
   `evalPool.ts:112-149`).
5. **The For-You strip is untouched**: its `LayoutBuilder` plus
   `onVisibleGameIdsChanged` post-frame loop (`tournaments_pane.dart:3751,3798`)
   re-inflates cards during layout on an adjacent surface that uses the same card
   widget.
6. **Behaviour under real mouse input on a release-quality build is unverified.**
   Every number here comes from a debug build driven by an in-app scroll driver.
7. **Windows only.** The measurement host is Windows; the changes are
   platform-neutral Dart, but nothing was exercised on another platform.
8. **The regression tests were not executed as part of this publication.**
   `AGENTS.md` makes `flutter analyze` on the changed files the only validation
   signal (no `flutter build`, no `flutter run`), so the tests are authored,
   analyzed, and left unrun here. They *were* executed in the throwaway
   measurement tree while the fixes were being developed (red → green for the
   reorder case).

## 4. How to reproduce the measurements

The harness is deliberately **not** part of this PR: it only ever existed in a
throwaway copy of this worktree (gitignored/untracked there too, and never built
into a shipped artifact).

* **Shadow tree**: a plain copy of the worktree at `<Windows temp>\ce-measure-shadow`,
  with the probe added as `lib/desktop/_shadow_frame_probe.dart` and the probe
  attached from the desktop entry point. Logs land in
  `<Windows temp>\ce-measure-shadow\_data\shadow_frames.log` (rotated per run to
  `shadow_frames_<label>.log`), stdout per run in `_data\app_stdout_<label>.log`.
* **Frame probe**: `WidgetsBinding.instance.addTimingsCallback` writes one `F`
  record per frame plus `E` events, `G` per-second counter deltas and `S` per-second
  summaries:
  `F <seq> <elapsed_us> <build_us> <raster_us> <vsync_us>`,
  `E <seq> <elapsed_us> <event> <value>`,
  `G <name> count=<n> sum=<v>`,
  `S <elapsed_us> t=<epoch_ms> frames=<n> over8300=.. over16600=.. over33300=..`.
  `E 0 <epoch_ms> probe.attach` anchors the log to wall-clock time;
  `E 1 <us> shadow.fix <0|1>` marks whether the candidate fix was enabled in that
  binary (`SHADOW_NOFIX=1` disables it, so one binary can serve both A and B).
  `A`/`T` records (ancestor chains, rate-limited stack samples) exist for
  attribution runs only (`SHADOW_TRACE=1`, `SHADOW_SHAPE=1`).
* **Scroll driver**: the grid hands its own `ScrollController` to a driver that
  waits for the surface to settle (`maxScrollExtent > 3000`, +6 s), then runs
  four `animateTo` phases at 25/50/75/100 % of the scroll extent, 2.5 s each with
  a 6 s settle, emitting `autoscroll.start` / `autoscroll.phase` /
  `autoscroll.done`. OS-level synthetic input cannot reach a background Flutter
  window, which is why the driver lives inside the app.
* **Analysis**: `python analyze_frames.py <log> [--from-wall <epoch_ms> --to-wall <epoch_ms>]`
  reports frames produced per second, build/raster/total median-p90-p99-max, the
  >8.3/16.6/33.3 ms buckets, a per-second timeline, the worst frames and the
  grouped counters. The windows used above are the driver's
  `autoscroll.start` → `autoscroll.done` wall times.
* **Launching a run**: stop any previous shadow instance, rotate the log, copy the
  shared session file into the shadow app's own Support directory (see caveat 1
  in section 5), then start the shadow `ChessEverDev.exe` with the deep link to
  the event/round under test and let the driver finish.
* **Run inventory** (the logs behind section 2, in `<...>\_data\`):

| Log | What it is | Window | Headline |
|---|---|---|---|
| `shadow_frames_cardgrid_before.log` | card grid, before round 1 | 60.1 s | 9.9 fps, build p50 42.19 ms, >33.3 ms 88.5 % |
| `shadow_frames_cardgrid_after1.log` | card grid, after round 1 (run 1) | 33.0 s | 18.0 fps, p50 18.36 ms, >33.3 ms 30.9 %, lookups 24/1290 gated |
| `shadow_frames_cardgrid_after2.log` | card grid, after round 1 (run 2) | 32.2 s | 18.9 fps, p50 20.45 ms, >33.3 ms 38.3 %, lookups 1082/1341 gated |
| `shadow_frames_boardrail_before.log` | Board-view rail scroll (rail fix in place) | 17.1 s | 48.5 fps, p50 2.95 ms |
| `shadow_frames_rA_mountstorm.log` | card grid, round-2 pre-fix counters | 34.6 s | 6,246 card mounts, 11,613 provider creates |
| `shadow_frames_abA_nofix.log` | round-2 A (fix disabled, same binary) | 34.9 s | 4,770 mounts, 3,398 memo-signature changes |
| `shadow_frames_abB_fix.log` | round-2 B (fix enabled) — **failed** | — | no `autoscroll` events: token error loop, no measurement |
| `test_fix_red.log` / `test_fix_green.log` | reorder element-survival test | — | `Actual: <0>` before, `All tests passed` after |

Counters quoted above (`card.build`, `card.mount`, `memo.sig.same/changed`,
`live.provider.create`, `shape.changed.round.*`, `grid.childbuild`,
`eval.scroll_gated`, `eval.scroll_gamebase_lookup`) are **shadow-only**
instrumentation; they are not in this PR.

## 5. Caveats for the reviewer

1. **Auth side effect.** The harness copies the shared Supabase session file so
   the shadow instance starts signed in. Two instances using the same session
   consume the refresh token: the second one starts failing with
   `refresh_token_already_used` and the run is worthless. This is exactly what
   killed round 2's after-run (section 3, item 1) — do not run two
   session-sharing instances at once, and re-seed the shadow session file per run.
2. **Debug build, Windows, synthetic driver.** No release build, no real mouse
   input, no non-Windows platform.
3. **Tests are authored, not executed here** — `AGENTS.md` makes `flutter
   analyze` the only validation signal. See section 3, item 8.
4. **Version/merge order.** `pubspec.yaml` is bumped one patch and one build over
   current `main` (`21.5.1+397` → `21.5.2+398`). Open PRs #256 and #257 carry the
   same `21.5.2+398`; whichever of the three merges second must rebase and re-bump
   both segments together.
5. **This is a draft.** No merge, no deploy, no release. The intended continuation
   is section 3 — most of all, re-measure round 2 and close the visible-window
   gap before anyone treats this as finished.

## 6. Web-parity gap list (tournament/broadcast Games wall)

Reference read: `Chessever/chessever-web-frontend` `main` @ `f8e6479` (clean
clone, verified against `origin/main`). Desktop surface ⇔ web `BoardCell` in the
`BoardGrid` wall, plus the compact rail rows (`RoundGameRow.tsx` /
`RoundGamesList.tsx`).

| # | Web technique | Web file:line | Desktop status |
|---|---|---|---|
| 1 | Rows virtualized on the document scroll plane | `BoardGrid.tsx:239-252,351-405` | MATCHES — `SliverGrid` + `SliverChildBuilderDelegate`, Flutter laziness |
| 2 | Row height computed, never measured | `grid-metrics.ts:44-64` | MATCHES — fixed `mainAxisExtent`/`childAspectRatio` |
| 3 | Column count computed once in JS | `BoardGrid.tsx:20-22` | MATCHES — `columnCountForWidth` |
| 4 | Per-cell paint/layout containment | `components.css:1621-1642` | MATCHES — per-card `RepaintBoundary` |
| 5 | Card memoized on the fields it renders | `RoundGameRow.tsx:294-312` | PARTIAL — inner card subtree memoized, not the outer card widget (section 3, item 3) |
| 6 | Stable cell key on the delegate's own child + index lookup | `BoardGrid.tsx:366-368`, `RoundGamesList.tsx:311` | **CLOSED in round 2** — key on the delegate's own child + `findChildIndexCallback`; 0/12 → 12/12 preserved |
| 7 | Visible-only live boards, mount budget | `BoardCell.tsx:130-146`, `mount-queue.ts:1-45` | MATCHES in spirit — no DOM/JS construction; element stability was the gap, closed by 6 |
| 8 | Evaluations only for the visible window | `evalPool.ts:1-24,112-149`, `RoundBoards.tsx:1368-1378` | PARTIAL — scroll gate exists (round 1); no visible-window target set |
| 9 | Wall reports its mounted window; stream carries only those boards | `BoardGrid.tsx:255-283`, `RoundBoards.tsx:1140-1157`, `useRoundData.ts:241-254` | PARTIAL — per-card scoped subscription + off-screen disposal, but no viewport report (section 3, item 4) |
| 10 | Refresh applies per-id deltas instead of rebuilding the list | `store.ts:190-232`, `RoundBoards.tsx:435`, `RoundGamesList.tsx:397` | PARTIAL — round 2 stops the remount; the outer card widget still rebuilds per refresh (section 3, item 3) |
| 11 | Per-group sections keyed | `StackedRounds.tsx`, `components.css:4585-4605` | **CLOSED in round 2** — per-group and per-round sliver keys |

Still open after both rounds: rows 5/10 (outer card memoization), row 8 (visible
-window evaluation targets), row 9 (visible-window report), plus the For-You
strip loop (section 3, item 5).

## 7. Files in this PR

| File | Carries |
|---|---|
| `lib/desktop/widgets/event_games_table.dart` | rail entry cache, lazy content-keyed entries, invoke-time inputs, scroll carry-over, clock `RepaintBoundary`, rail test counter |
| `lib/desktop/widgets/tournament_games_view.dart` | per-card `RepaintBoundary` + memo, scroll-time eval gate, sliver/card keys, `findChildIndexCallback` |
| `lib/desktop/widgets/tournament_standings_view.dart` | keyed standings rows |
| `lib/screens/chessboard/provider/current_eval_provider.dart` | `gameCardEvalScrollGate`, opt-in `CHESSEVER_EVAL_TRACE` |
| `lib/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart` | select-scoped live watch + `liveGameCardContentKey` |
| `test/desktop/event_rail_row_reuse_test.dart` (new) | rail row-reuse contract |
| `test/desktop/tournament_games_view_performance_test.dart` | reordered-round element-survival case |
| `docs/desktop_live_event_performance_handoff.md` (this file) | handoff |
| `pubspec.yaml` | `21.5.2+398` |

**Shared file, split hunk by hunk:** `event_games_table.dart` is also touched by
open PR #256 (external-PGN compatibility). Its two hunks — the
`pgn_external_compat` import and the `toExternalCompatiblePgn(...)` clipboard call
— are **excluded** here and remain only in #256; this PR's copy of the file was
derived from a pristine `origin/main` blob plus only the performance hunks and
verified byte-for-byte.

**Deliberately excluded** (published elsewhere or not product code): the PR #256
external-PGN files and the PR #257 "Show in folder" files; `build/`,
`.dart_tool/`, `.env*`, run logs and `.hermes-logs/`; analyzer-compare helper
scripts; probe/scratch sources; and the whole measurement harness described in
section 4.

## 8. Validation run for this publication (2026-09-19)

* **Focused `flutter analyze`** over the seven changed Dart files: **exit 1**,
  **2 issues**, both `info`-level `deprecated_member_use` (`cacheExtent` →
  `scrollCacheExtent`, `tournament_games_view.dart`). Both are pre-existing on
  `origin/main` (same usage at `tournament_games_view.dart:706,1444,1465`), i.e.
  not introduced here; the analyzer exits 1 whenever any issue exists.
* **Whole-project `flutter analyze`**, publication worktree vs a pristine
  `origin/main` archive of the same target (`42f6cff8`, 5,532 files):
  **265 vs 265 issues**, and a normalized diagnostic-tuple comparison shows
  **0 introduced / 0 removed** diagnostics.
* `git diff --check` clean; secret scan over the staged diff clean (no
  credentials, tokens or personal paths in the delta).

