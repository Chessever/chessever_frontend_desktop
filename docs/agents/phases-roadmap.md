<!-- Moved verbatim from AGENTS.md Part I (formerly CLAUDE.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

## 7. Phases (the roadmap)

1. **Foundation** — write CLAUDE.md + AGENTS.md (this), bootstrap desktop runners, replace pubspec packages, wire `sqflite_common_ffi`, get `flutter run -d macos` past `main()`.
2. **Engine** — replace `stockfish` package with bundled-binary UCI driver behind existing `StockfishEngine` interface, both platforms.
3. **Auth** — implement OAuth loopback flow for Google and Supabase-hosted Apple OAuth on desktop; verify Supabase session persists.
4. **Shell** — desktop scaffold (sidebar + top menu + content pane + command palette) using forui. Wire existing tournament list as the first pane.
5. **Panes** — port board, analysis, library, favorites, calendar, players to multi-pane layouts. Add keyboard shortcuts and right-click menus.
6. **Services** — analytics over HTTP, local notifications, file-drop intake, single-instance, window state persistence.
7. **Polish & build** — `flutter build macos` + `flutter build windows` green, signed/notarized macOS .app, MSIX/installer Windows package, basic smoke test on both OSes.

We are at **Phase 1**. Do not skip ahead.
