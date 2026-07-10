# Player Detail Header Removal

## Goal

Remove the redundant top header row from an opened player's detail page while preserving the main Players library header.

## Behavior

When no player is open, the Players library continues to show its existing **Players** header and **Add player** action.

When a player is open, the page does not render the header row containing **All players**, the player icon/name, game count, or **Add player**. The source rail and main detail tabs move up into that space with normal top padding. No replacement Add player flow is introduced on the detail page.

## Verification

- The Players library still exposes **Add player**.
- Opening a player removes the complete header row and its controls.
- The detail content retains intentional top spacing.
- `flutter analyze lib/desktop` reports no issues.

## Scope

This is a layout-only removal. It does not change player data, source actions, tabs, tree behavior, or the main Players library workflow.
