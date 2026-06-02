# lib/desktop/

Desktop-only code for the macOS + Windows port. See `/CLAUDE.md` and `/AGENTS.md` at repo root for the rules.

Layout:

- `desktop_app.dart` — top-level shell wrapper, instantiated from `main.dart` when `Platform.isMacOS || Platform.isWindows`.
- `shell/` — sidebar, top bar, command palette host.
- `panes/` — content panes that wrap existing widgets from `lib/screens/`. One pane per primary feature.
- `services/` — window manager glue, hotkey registration, file-drop intake, native menu bar.
- `platform/` — files that branch on `Platform.isMacOS` vs `Platform.isWindows` for OS-specific behavior.

**Rule:** desktop code wraps and reuses `lib/screens/*` widgets; it does not reimplement them. The mobile shell stays in place until the desktop shell covers every feature.
