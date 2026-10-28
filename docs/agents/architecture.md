<!-- Moved verbatim from AGENTS.md Part I (formerly CLAUDE.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

## 5. Architecture (target)

```
lib/
  main.dart                       # entrypoint: branches on platform; on desktop, runs DesktopApp
  desktop/                        # NEW — desktop-specific code lives here
    desktop_app.dart              # MaterialApp/forui shell wrapper
    shell/                        # sidebar, top bar, command palette
    panes/                        # board_pane, analysis_pane, library_pane, etc.
    services/                     # window_manager, hotkeys, file_drop, menu_bar
    platform/                     # macos/windows-specific glue (notifications, single-instance)
  mobile/                         # (optional, future) wraps existing screens for mobile shell
  screens/                        # EXISTING — feature widgets reused on both shells
  repository/, providers/, services/   # EXISTING — unchanged domain layer
  theme/, widgets/, utils/        # EXISTING — shared
```

Desktop screens reuse the existing `screens/<feature>/` widgets. They wrap them in pane layouts; they do not reimplement them.
