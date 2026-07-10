# Player Build Tree Auto-Open

## Goal

When a user presses **Build Tree** for any source in a player's Build Tree tab, open that source's completed tree immediately after a successful build. The user must not need to press the replacement **Tree** button.

## Design

`LocalChessLibraryNotifier` will expose an additive awaitable build entry point that resolves with the `PlayerOpeningTreeIndex` produced for the requested path. Existing background scheduling remains non-navigating and existing callers keep their current API.

The Players pane will await only the build started by the pressed button. When it receives a usable index and the initiating pane is still valid, it will call the existing `_openLocalTree` path. This preserves the source title, player metadata, preparation colour, board-tab behavior, and right-rail tree selection already used by the **Tree** button.

Failed, cancelled, stale, or superseded builds resolve without opening a tab. A single button press opens at most one tree tab.

## Verification

- A widget regression presses **Build Tree** once and proves the completed tree is opened without a second press.
- Existing persisted-tree **Tree** actions continue to open normally.
- Failure does not navigate.
- `flutter analyze lib/desktop` reports no issues.

## Scope

This change affects only user-initiated builds in the Players Build Tree tab. Background tree generation and recovery behavior remain unchanged.
