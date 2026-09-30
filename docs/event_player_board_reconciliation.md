# Event-player Board publication and reconciliation

## Review boundary

This feature is stacked on `freemium/09-integration` at
`3828671e85a540d5dcc83a1a18b6dc3bc4001985` (PR #250), not on main.
That verified ancestor contains the exact heads of #246 and #247, and their
integration wiring. Review only this branch's delta; it does not republish the
freemium changes as a competing main PR. No dependency branch was edited.
After #250 lands, transplant this feature delta onto current main, retarget the
PR, recompute the one-step version bump, and re-analyze before merge.
Publication version is **20.32.24+373**, exactly one patch/build above the declared
stack base's 20.32.23+372. This is not a release or deployment request.

## Behavior

- Compact and full event performance card game rows open a new independent
  player · event Board tab, selecting the clicked game. Its rail contains only
  that player across all rounds in the canonical event/category tour siblings.
- The receiving tab owns history; rail collapse, keyboard stepping and detached
  payloads retain the scope. No shared tournament selection is changed on a
  player-scoped rail step.
- Compact name/avatar opens the full performance card. Its heading is passive;
  no Open event games button or compact Open player profile action is added.
  The full card retains its explicit profile action.
- Canonical player identity, paginated FIDE/name query union, custom points and
  PGN save identity are retained. The repository change is limited to paging
  the existing event-player query; #246's Smart Event query section is untouched.

## Conflict decisions and security seams

All actual textual conflicts were **disjoint intent**, combined rather than
choosing one developer's file:

- `event_games_table.dart` import conflict: keep both access-context and
  event-player imports. Existing pre-fetch admission, source provenance and
  ownership stripping remain; add only player-scoped rail selection.
- `tournament_games_view.dart` two signature conflicts: retain `accessContext`
  and add `eventPlayerScope` in the builder and open helper. Admit BEFORE tour
  resolution/PGN hydration, recheck after hydration, preserve empty-tab guard.
- `player_score_card_view.dart` activation conflict: the new event path calls
  the centrally admitted tournament helper; the non-event path keeps #247's
  pre-hydration admission and post-await check. Favorite-limit paywall stays.
- `active_board_game.dart` / detached payload: additive scope combines with
  existing accessContext, conservative inference, ownership and admission latch.
  The subset does not become the paid global player-profile continuation.
- `board_pane.dart` compact game activation explicitly passes
  `args.sourceAccessContext`: Countrymen/Smart sources do not become free just
  because the rail is narrowed. Ordinary event broadcasts remain free.
- `active_player.dart` adds optional score-card source context, propagated from
  Board through the full card and its game opener. This prevents the new
  compact -> full -> game path from losing an existing paid origin.

The source candidate contains unrelated engine/video work. Publication excluded
all engine/video files and removed the engine-only Board retarget hunk and all
mini-eval tab-bar hunks; only the tab label condition is retained in the tab bar.
Source hashes were checked against the preflight snapshot; the Development
worktree, runtime, shortcuts and primary dirty checkout were not modified.

## Verification and limitations

Whole-repository `dart analyze --format=machine`: **264 diagnostics on the base,
264 on the candidate; zero introduced, zero resolved**, after normalizing paths
and line offsets. Existing third-party test errors remain baseline, so this is
not a claim that the whole repo is analyzer-clean. Focused Flutter analysis is
recorded in the PR. Diff whitespace and staged secret-pattern gates are required.
Regression coverage includes scope/identity, activation routes and a new
admission-reconciliation test; tests were authored/analyzed, NOT executed.
No build, run, app launch or visual verification was performed for this stacked
artifact. Prior user-confirmed name-flow behavior belongs to the Development
candidate, not this reconciled publication.

## Queue coordination

Pre-publication queue: 13 open; 6 DIRTY, 4 BLOCKED, 3 CLEAN; 3 existing
`devberkay` review requests. `pause_new_requests=true` for independent main PRs.
Decision: **stack/reconcile**, not a duplicate main PR. Hot seams include Board,
rail and admission (#238/#247), tab bar (#249/#241), payload (#249/#247), and
repository (#246). The approved review exception is one focused request on this
stacked delta. #241 and #240 are separate dependencies only if their unrelated
features are desired; they are not included here. Do not merge this PR into the
review-only dependency branch or deploy it as a standalone release.
