# Players Controls and Year Chart Polish

## Goal

Make the Players Overview and Games surfaces use ChessEver's established
time-control artwork, align the Games toolbar controls, and make the Games by
Year chart pleasant to hover and scroll without layout jumps.

## Time-control artwork

The Players Overview time-control selector must render the same original,
untinted PNG artwork used elsewhere in the app:

- Classical: the existing white owl;
- Rapid: the existing white rabbit;
- Blitz: the existing blue lightning mark;
- Bullet: the dedicated yellow bullet asset;
- UltraBullet: the dedicated red ultrabullet asset.

The selector continues to derive categories through `TempoIcon`, but this
surface must not recolor the asset with the category accent. Selected state is
communicated by the pill background, border, and label, leaving the brand art
unchanged. Unknown categories retain the existing safe fallback.

## Games toolbar controls

The database Games toolbar uses one 36 px control height across:

- the search field;
- the Filters action;
- the Clear filters action;
- the loaded-count indicator.

Filters and Clear filters share the desktop shell's custom control vocabulary:
an 8 px radius, restrained resting border, hover fill, compact icon and label,
and hover/press motion. The active Filters control retains its accent border,
fill, and count badge. Clear filters is a secondary action with matching
geometry rather than a larger stock button. The loaded count is visually
aligned but remains muted and non-interactive.

The change is local to this toolbar and its reusable game-filter controls. It
does not redesign unrelated buttons across the application.

## Games by Year interaction

The chart keeps a stable layout before, during, and after pointer hover.
Hovering a year must not insert or remove a child below the chart, alter the
panel height, change the dashboard scroll extent, or move content below it.

Year details are rendered as a compact floating layer inside the chart panel.
The overlay follows the selected year without participating in layout and uses
`IgnorePointer`, so it cannot capture clicks, wheel events, or trackpad input.
It is positioned within the available chart bounds and remains readable near
either edge.

The dashboard's compensating 160 px bottom padding is removed. A vertical
wheel or trackpad gesture over the chart continues scrolling the dashboard.
Horizontal chart scrolling remains available when the number of years exceeds
the viewport, with the existing scrollbar affordance. Clicking a year still
hands the exact year filter to the Games tab.

## Verification

Widget tests will prove:

- each known time-control category resolves to its intended dedicated asset;
- the selector renders original artwork without a color filter;
- the Games toolbar controls have matching 36 px heights;
- active-filter and clear-filter behavior remains correct;
- entering, moving within, and exiting the year chart does not change its
  panel height or the dashboard's scroll extent;
- vertical scrolling works while the pointer is over the chart;
- clicking a year still emits the correct Overview-to-Games filter request.

Changed Dart files must pass targeted `flutter analyze`. Existing relevant
widget and repository tests must remain green. Per repository policy, no
`flutter build` or `flutter run` command is used for validation.
