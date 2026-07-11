# Event Rail Future-Round Behavior

## Goal

Keep published future rounds discoverable in the in-board event rail without
letting their game rows interrupt an active round. When Round 4 is live and
Round 5 has published pairings, the rail should read:

1. Round 5 header, collapsed
2. Round 4, live and expanded
3. Round 3
4. Round 2
5. Round 1

## Scope

This change applies only to the desktop in-board event rail implemented by
`event_games_table.dart`. It does not change shared mobile round ordering,
tournament-domain providers, or non-event rails.

## Ordering

- Published upcoming round headers appear before started rounds, with the
  nearest upcoming round first.
- The active live or ongoing round follows the upcoming headers.
- Earlier started rounds follow newest-first, preserving the existing generic
  round-number ordering for standard `Round N` events.
- Placeholder-only future rounds with unresolved players remain hidden under
  the existing filtering rules.

## Expansion

- When any round is live or ongoing, upcoming rounds default to collapsed.
- Live, ongoing, and completed rounds retain their current expanded default.
- When no round is live or ongoing, the nearest published upcoming round may
  use the normal expanded default so its pairings can surface after the latest
  round has finished.
- A user's explicit header toggle continues to override the initial default for
  the lifetime of that auto-disposed rail state.

## Implementation Boundary

Derive the initial expansion state from the complete set of desktop event-rail
groups. Keep the state keyed by the round plus its initial default so future
rounds can initialize collapsed without changing unrelated rails. Reorder only
the groups returned to the desktop event rail; do not modify
`sortRoundsForDisplay`, because that ordering is shared with the mobile Games
tab.

## Verification

Add or update focused tests for:

- a published future round above a live round, with the future rows collapsed;
- live/current and completed rounds ordered `4, 3, 2, 1` beneath it;
- the nearest upcoming round expanding normally when no round is live or
  ongoing;
- unresolved placeholder future rounds remaining hidden.

Run `flutter analyze` as the repository's required validation signal.
