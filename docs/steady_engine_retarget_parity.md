# Steady native engine retargeting

## Authority and scope

Source: `Chessever/chessever-web-frontend` merged PR400, commit
`539da28f738510323780cf43699988b56f1813b2` (also remote `main` at audit time).
Target: `Chessever/chessever_frontend_desktop` remote `main`,
`e54f6884885069e3e3d641707cccf48735228303`, version `20.32.13+362`.
This is the PR400 steady-readout behavior, not PR392 engine-default changes.
No preference defaults, line counts, arrow counts, updater files or release
artifacts are changed. Publication bumps the base once to `20.32.14+363`.

Open-PR audit: PR238 also touches `board_pane.dart` for access policy; this
change adds only the gauge's `retainWhileRetargeting` opt-in there. PR239/240
concern video; this PR shares only `pubspec.yaml` with them. All four video
source/test/documentation paths already published in PR240 are excluded.
Their worktrees and the cumulative Development candidate are not modified.
All currently use `20.32.14+363`; whichever lands later must rebase/re-bump.
Existing PR238 P1/P2 and PR240 P2 review findings are outside this scope and
are not represented as resolved by this PR.

## Main and mini evaluation midpoint parity

Web PR398 supplies the visual reference: a fixed 50% midpoint, 3 logical
pixels thick, grey `#808080`, independent of score, orientation and loading.
The shared Desktop midpoint widget covers the main bar, mini game-card bars
and tab preview bars. The cyan main evaluation badge is displaced only when
needed to preserve 2 logical pixels of clearance from the fixed marker;
score placement otherwise follows the existing behavior. Authored geometry
regressions cover midpoint placement and near-zero badge clearance, but have
not been executed.

## Reachable source and native invariant map

| Source at the exact merge | Native production path / adaptation |
| --- | --- |
| `FocusBoard.tsx` imports and calls `useEngine`; header reads its first displayed line | `BoardPane` instantiates `EnginePanel`; one Consumer projects the complete displayed state to header score/depth and all PV rows. Report subtree identity is retained across engine-only ticks. |
| `engine-display.ts`: retarget keeps the last whole reading; publish replaces it | `EngineDisplay` is panel-local, containing the source FEN and whole `BoardEvalState`. Retargeting never copies old PVs into `boardEvalProvider(newFen)`. |
| `useEngine.ts`: wait for the expected number of usable PV rows | `CompletePvBatch` belongs to one UCI job, validates rank bounds and publishes all ranks at one real depth. A partial higher-depth iteration cannot relabel the previous complete iteration. Expected count is capped by the position's legal root moves. |
| `FocusBoard.tsx`: `linesCurrent` gates arrows, keyboard best-line action and play; render SAN with `linesFen` | Native arrows, keyboard insertion and share evaluation still read the exact-FEN authoritative provider, never the display cache. Retained rows use their original FEN, disable pointer/hover preview, and have no play dispatcher. Delayed menu play captures the original dispatcher, checked against target generation, foreground status, settings and snapshot identity. |
| `engineSession.ts`: stop waits for bestmove; stop timeout retires worker | The native singleton now subscribes before stop and holds its serial queue until bestmove. `readyok` alone is not a search barrier. Timeout retires only the owned process; queued tab/report jobs are not globally cancelled. Ordinary navigation reuses a healthy engine and its transposition hash. |
| `useEngine.ts`/session: obsolete work cannot repaint the active target | The provider invalidates the request when its final listener detaches; a return during auto-dispose grace creates a new owner. An optional request predicate is checked before enqueue, after preemption/readiness awaits, and in stream callbacks. Provider callbacks/final completion also check their captured generation. |
| off/terminal/error clear retained output | Disabled/background/report-paused panels clear display state. Terminal state is known at provider construction. Cancelled/failed/empty final evaluations cancel pending UI publication and clear authoritative state. Fatal search timeouts no longer return successful partial evaluations. |
| preserve visible evaluation while searching | Board gauge opts into display-only numeric/mate retention; initial unknown is still loading. A failed/off state clears the gauge. The Explorer gauge keeps its existing default behavior. |

## Consumer and lifecycle audit

- `BoardPane` share/save image reads `boardEvalProvider(position.fen)`; no
  retained display values enter an exported current-position evaluation.
- `BoardPane` keyboard PV insertion reads the board/analysis FEN provider.
  It never reads `EngineDisplay`; during initial retargeting its PV string is empty.
- `_BoardArea` arrow projection reads current analysis FEN PVs. Threat mode
  continues to use its existing analysis FEN resolver; retained PVs cannot draw
  arrows on the replacement board.
- `_PvLine` pointer play and delayed context-menu play are guarded. The
  existing preview overlay is disabled while retained; no stale hover target
  may project an old PV against the new position. No PV drag insertion path
  exists in this panel. No keyboard binding or notation focus/scroll key changed.
- Report generation uses its separate controller/job ownership and never reads
  display cache. The shared UCI transport fix is necessary because native jobs
  do not carry generation IDs in their output; a UI-only cache would leave the
  old-output/new-FEN race intact. Full-batch publication is opt-in for Desktop
  board jobs, keeping existing report/background callback behavior.
- Engine on/off retains its existing settings and defaults. The toggle's
  post-stop and post-load ownership checks prevent an older off operation
  from clearing/persisting over a newer on while the native stop barrier waits.
  Global cancellation removes only jobs present at invocation and retains the
  serial processor lock; a later on request is not erased after the await.
- Live panel scope is its retained tab widget. Leaving foreground clears its
  cache, and returning cannot adopt another tab's display. There is no global
  last-evaluation cache introduced by this port.

## Authored regressions (not executed)

- `steady_engine_batch_test.dart`: rank completeness, full iteration depth,
  partial deeper iterations, stale shallow lines, independent search batches.
- `steady_engine_display_test.dart`: A-B-A display retention versus current
  provenance; terminal/off/error clearing; independent tab caches; actual
  provider final-listener invalidation and fresh-owner resubscription.
- `steady_engine_panel_test.dart`: real EnginePanel with controlled provider,
  three retained rows, no Searching replacement, stable list rectangle,
  unplayable retained PV and failure clearing.
- `steady_engine_session_test.dart`: fake UCI transport through the actual
  singleton; readyok cannot release a stopped search; latest queued A wins over
  superseded B; atomic callbacks/final result; stop timeout retires the old
  transport and rejects late output.
- `steady_engine_gauge_test.dart`: retained mate score, error clear and initial
  unknown loading behavior.

## Verification boundary

Publication verification follows repository analyze-only policy: tests are
authored and statically analyzed, not executed; no build, test or app launch
is performed for the isolated publication tree.

Separately, the user-authorized cumulative Windows Development candidate
`20.32.14+363` built successfully before publication. That candidate includes
the already-published PR240 video changes, which are excluded from this PR.
Its final source was frozen and hashed. All publication source/test bytes
match that candidate; only this documentation is updated for handoff. The
manifest already equals the fetched base plus one patch/build increment.
The focused publication artifact itself has not been built.

The corrected Board screenshot showed `+0.34` with clear badge/marker
separation; this is not runtime proof of the exact near-zero collision case.
The first candidate launch unexpectedly exited for an unknown reason; a
relaunch was responsive with no error-like logs observed. This is limited
Windows evidence, not comprehensive QA or macOS verification.

Geometry assertions remain unexecuted. Runtime QA on both native platforms
remains a release gate, especially rapid navigation, hover/menu-open
retargeting, foreground switches, report handoff, limited-legal-move
positions, engine failure recovery and exact near-zero badge clearance.

Historical baseline focused analyzer: `No issues found!` for the six existing
modified production paths at the target SHA. The initial steady-engine-only
13-path analyzer also returned `No issues found!`, exit 0. Final publication
analysis covers all 20 Dart source/test paths; see the PR verification record.
Dependencies are unchanged; dependency-resolution-only lockfile churn is
excluded from publication.
