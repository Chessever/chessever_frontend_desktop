# Chessconnect adapter (app.chessever.com)

Chessconnect (chessconnect.de, Dr. Jörn Gehring) connects electronic
chessboards (DGT, Chessnut, Millennium, Certabo, ChessUp, robots) to chess
sites through a Chrome/Edge extension and Android/iOS apps that load the web
page. The browser build exposes its Adapter API v1 as
`window.chessconnectAdapter` and a `#chessconnect-root` element for the
connect button.

| Surface | What Chessconnect sees | What a board move does |
|---|---|---|
| Play vs Stockfish, Leela, Maia | User's colour, live position, clocks, result | `PlaySessionNotifier.playHumanMove`: only on the user's turn, never a premove, no promotion dialog |
| Board tab (analysis, broadcasts, collections, imported PGNs, Game Report) | The position shown, orientation; `playerColor: both`, no clock or result (spec 4.8) | Follows the line or adds a variation, like a mouse move |
| Anything else | `getState()` returns `null` | Refused |

Code: `lib/desktop/services/chessconnect/` (shared rules and sources),
`lib/web/chessconnect_adapter_web.dart` (JS object, change event, root
element), `lib/desktop/widgets/chessconnect_slot.dart` (button room under the
board). Tests: `test/desktop/chessconnect_bridge_test.dart`.

## Security rules (do not loosen)

- **Nothing new reaches our servers.** No endpoint, key, token or third-party
  script is added. Chessconnect's code runs in the user's own browser, only
  after that user grants it this site. We never load its code.
- **Only what is on screen leaves.** Position, colour to move, orientation,
  Play clocks and result. No names, accounts, ratings, engine or Toby output,
  bot identity, or database/broadcast ids: game ids are opaque per-page tokens
  (`ce-<random>-<n>`).
- **Only a legal board move gets in.** `move()` accepts a strict UCI string
  (`^[a-h][1-8][a-h][1-8][qrbn]?$`), at most 8 per second, to the focused
  board only, and through the same legality and turn rules as a mouse move.
  Takeback, resign, draw, navigation and settings are not exposed.
- **The object cannot be tampered with.** It is frozen and defined read-only,
  non-configurable on `window`, and installed only in the top-level window
  (never when another site frames the app).
- **Never throws.** `getState()` and `move()` turn every failure into `null`
  or `{ok: false}`.
- **No human-opponent games.** If online play against people is ever added,
  decide fair-play rules before attaching it.

## Kill switches

1. Ours: build the web app with `CHESSCONNECT_ADAPTER_DISABLED=true` in the
   `WEB_PUBLIC_CONFIG` file (allowlisted in `scripts/build_web.sh`) and
   redeploy. The adapter object and the slot are then never created.
2. Chessconnect's: it removes the site from its signed site list, or keeps it
   behind an access code.

## Known limits

- Chess960 is not offered in Play, so `variant` is always `standard`.
- The connect slot only takes space after Chessconnect has called
  `onConnectionChange`, and shrinks to 1 px when it stays empty (the phone
  apps show their own status).
