# Opening Explorer Source Control and Game Columns Design

## Goal

Simplify the opening explorer controls and make its game table consistently useful. The explorer must no longer show the top `Both / W / B`, `Global / Local`, or settings controls. Source selection moves beside the bottom-left opening-book button. Every visible game row must show its year and notation when those values exist in the underlying game data.

## User experience

- Remove the opening explorer's top source/filter toolbar in full.
- Remove the explorer-specific `Both / W / B` selector permanently. It is not relocated.
- Place one compact source button immediately after the bottom-left opening-book toggle.
- Keep this source button in the selected/accent visual state regardless of whether Global or a local database is active.
- Label the button `Global` for the global explorer and use the selected local database's exact display name otherwise.
- Clicking the button opens the existing desktop context-menu treatment with `Global` first, followed by every available local database. The active entry is marked.
- The explorer's existing source-loading, empty, and error states remain responsible for the content area. A failed source load does not silently select another source.
- The existing filter popover, when available, follows the source selector in the bottom bar.

## State design

The bottom segment bar and opening explorer currently live at different levels of the notation panel. Introduce a small controller/model owned by the notation panel state and shared with both widgets. The explorer publishes its available sources, active label, and selection callback through that controller; the bottom bar observes it and renders the selector.

This keeps the existing source-selection and local-tree-loading behavior in the explorer instead of lifting the entire explorer state into the parent. The controller must be disposed with its owner and must avoid notifications after the explorer is unmounted.

If the explorer is closed or source selection is unavailable, the bottom source button is not rendered. `Global` remains selectable even when no local databases exist.

## Game-row data design

The table should consume one canonical row shape for both global and local sources:

- `date`: the game's stored date or year-compatible value.
- `continuation`: the SAN continuation beginning at the current position.

Diagnosis begins with a regression test using a local tree row that contains known source game metadata. The fix belongs at the row-loading/normalization boundary so the presentation layer does not accumulate source-specific field guesses. Existing tolerant formatting remains: a full date displays its year, a year-only value displays that year, and genuinely absent values display an em dash.

Notation should continue to prefer a position-aware continuation supplied by the loader. If it must be derived from PGN, that derivation occurs in the loader using the current position and requested notation-ply limit, not by rendering raw PGN text in the cell.

## Verification

Widget and unit coverage will prove:

1. The top `Both / W / B`, `Global / Local`, and settings controls are absent.
2. The source selector is rendered beside the opening-book toggle and shows the active source.
3. Its menu includes Global and all available local databases, and selecting an entry updates the explorer and label.
4. A representative local game row displays its expected year and notation.
5. Existing explorer navigation and source error handling remain intact.

Run focused tests for the changed widgets/loaders, followed by `flutter analyze` as the repository's required validation signal.
