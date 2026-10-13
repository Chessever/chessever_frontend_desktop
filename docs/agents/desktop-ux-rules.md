<!-- Moved verbatim from AGENTS.md Part I (formerly CLAUDE.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

## 4. Desktop UX rules (the part that actually changes from mobile)

The mobile app navigates through pushed routes. The desktop app does not push routes for primary navigation; it switches the **content pane** while the **shell** persists.

- **App shell:** persistent left sidebar (Tournaments, Library, Favorites, Players, Calendar, Countrymen, Settings), top window-chrome with platform menu bar, optional right inspector pane.
- **Multi-pane layouts:** the analysis screen shows board + move list + engine PVs + game header simultaneously; resizing is mouse-driven via splitters.
- **Keyboard-first:**
  - `←` / `→` step through moves; `↑` / `↓` jump to first/last; `Space` toggle autoplay.
  - `Cmd/Ctrl+K` open command palette (jump to tournament/player/feature).
  - `Cmd+Shift+F` on macOS / `Ctrl+Shift+F` on Windows opens global search from every pane, route, feature state, and nested Library/Players view. This is a shell-level invariant: new panes, route wrappers, focus scopes, shortcuts, text fields, and feature-level actions must not shadow or disable it.
  - `Cmd/Ctrl+O` open PGN; `Cmd/Ctrl+S` save current game; `Cmd/Ctrl+E` toggle engine; `Cmd/Ctrl+F` find in current view.
  - `F` flip board; `A` request analysis; `Esc` close active dialog/inspector.
- **Mouse:**
  - Hover tooltips on every move and eval-bar segment.
  - Right-click any move → context menu (annotate, branch, copy FEN, jump to engine line).
  - Drag-drop PGN files into the window → import.
  - Double-click on a tournament/game row → open in main pane.
- **Window:** resizable, min size 1024×720, remembers position and pane sizes between sessions.
- **No bottom nav, no hamburger drawer, no full-screen modal sheets** — those are mobile patterns.
