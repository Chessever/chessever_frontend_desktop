# Integrated Desktop Title Bar Design

Date: 2026-07-11

## Goal

Make ChessEver's desktop window read as one continuous application surface on macOS, Windows, and Linux. The sidebar background must reach the top-left edge, the tab-strip background must reach the top-right edge, and no separate native toolbar may sit above the Flutter shell.

## Supported Platforms

- macOS keeps the native traffic-light buttons, positioned over reserved space in the sidebar header.
- Windows and Linux hide the native caption controls and render compact ChessEver window controls at the right edge of the tab strip.
- All three platforms use the existing 46 px sidebar-header/tab-strip row as the title-bar surface. The change must not add another row or reduce pane height.

## Window Configuration

`DesktopWindow.initialize` continues to initialize `window_manager`, calculate the current-display-aware initial size, enforce the effective minimum size, and show the window after it is ready.

The window uses `TitleBarStyle.hidden` so Flutter content extends into the title-bar area. Native window buttons remain visible only on macOS. The existing dark window background remains in place to prevent startup flashes. The native frame is retained; the app does not switch to a fully frameless window, preserving platform resize borders, shadows, and system window behavior.

Existing bounds persistence, close prevention, shutdown coordination, native update entry points, and multi-window setup remain unchanged.

## Shell Chrome

The existing top chrome stays split along the same vertical boundary as the rest of the shell:

- `DesktopSidebar` owns the left header segment and continues painting `kBlack2Color` through the top-left corner.
- `DesktopTabBar` owns the right segment and continues painting `kBlack2Color` through the top-right corner.
- Their shared bottom divider remains collinear.

On macOS, the sidebar header reserves enough leading width for the traffic lights. The sidebar toggle stays reachable and aligned without overlapping native controls in expanded or collapsed sidebar modes.

On Windows and Linux, a dedicated window-control cluster is placed after the existing update/profile actions in `DesktopTabBar`. It provides minimize, maximize/restore, and close. The controls use project colors and hover/press feedback, with the close button using the conventional destructive red hover state. They are custom desktop chrome controls rather than Material `IconButton`s.

## Drag and Interaction Behavior

Only non-interactive gaps in the sidebar header and tab strip initiate window dragging. Tabs, drag-reorder handles, history controls, the sidebar toggle, update UI, profile UI, and window controls retain their existing pointer behavior.

Double-clicking draggable chrome maximizes or restores the window through `window_manager`. The maximize control reflects the current maximized state and updates when the window is maximized, unmaximized, or restored through either app controls or the operating system.

Window-control buttons expose tooltips and semantic labels. Keyboard navigation and the shell-level global-search shortcuts are unchanged.

## Component Boundaries

- `DesktopWindow` owns native window configuration.
- A focused desktop window-controls widget owns Windows/Linux caption actions and window-state observation.
- Sidebar and tab-bar widgets own placement of draggable regions around their existing interactive children.
- No domain repositories, providers, panes, updater internals, or mobile screens are modified.

## Failure Handling

Window actions are asynchronous. Button handlers avoid overlapping repeated actions and tolerate a window state changing between query and command. UI state is refreshed from `WindowListener` callbacks rather than assuming a maximize or restore command succeeded.

The desktop shell remains usable if a window action fails; failures do not replace pane content or break navigation.

## Verification

The implementation is verified with `flutter analyze`, the repository's required validation signal. The final code review checks that:

- macOS reserves native traffic-light space without overlapping the sidebar toggle;
- Windows and Linux expose all three caption actions;
- draggable regions do not cover interactive chrome;
- double-click maximize/restore remains available through `DragToMoveArea`;
- saved bounds, minimum-size handling, close coordination, and global-search shortcuts remain wired;
- no Material chrome control is introduced under `lib/desktop/`.

Runtime visual confirmation on each operating system belongs to the user/release smoke-test flow and does not require a local `flutter build` or `flutter run` during implementation.
