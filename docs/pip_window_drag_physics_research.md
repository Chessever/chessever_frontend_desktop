# PiP window drag physics research

Date: 2026-08-25

## Question

Can the live-game PiP remain an operating-system-native draggable top-level
window, then use the release velocity to "throw" and smoothly settle against a
safe screen edge or corner on macOS, Windows, and Linux? Could the Flutter
`motor` package supply that behavior?

## Verdict

Not as one reliable, identical feature across all three platforms.

- Windows exposes the information needed for an accurate implementation.
- macOS preserves an excellent native drag, but the public AppKit drag handoff
  does not provide a dependable mouse-up or drag-ended callback to the current
  Flutter plugin. It would need additional native code and runtime validation.
- Linux under X11 may be approximated, but behavior remains window-manager
  dependent.
- Native Wayland is the hard blocker: a normal client cannot reliably discover
  or command the global position of a top-level window. That makes a
  client-driven trajectory to a screen edge non-portable.

`motor` can calculate changing `Offset` values. It cannot drag or reposition an
operating-system window. Each generated value would still need a supported
native window-position call, so it does not solve the Wayland or drag-release
problems.

If matching behavior on macOS, Windows, and Linux is a requirement, this should
not ship. A narrower Windows/macOS experiment could be reasonable behind a
platform capability gate, with native dragging left unchanged everywhere.

## Platform matrix

| Platform | Native drag | Position samples | Reliable drag end | Programmatic landing | Assessment |
| --- | --- | --- | --- | --- | --- |
| Windows | Yes | Yes, `WM_MOVING` includes the current screen-coordinate rectangle | Yes, `WM_EXITSIZEMOVE` is emitted once | Yes, `SetWindowPos`; custom animation frames are required | Feasible, highest confidence |
| macOS | Yes, AppKit hands the drag to Window Server | Move notifications and frame reads exist | Not from `performDrag(with:)`; Apple says it returns immediately and mouse-up may not arrive | Yes; AppKit has an optional built-in frame animation, or the app can submit positions | Feasible only with extra native release detection and a prototype |
| Linux/X11 | Yes, delegated through GTK to the window manager | Configure events and positions are available, with documented reliability caveats | No finished-move callback in `window_manager` 0.5.1 | `gtk_window_move` is only a request and may be ignored or adjusted | Possible approximation, not uniform or guaranteed |
| Linux/Wayland | Yes, compositor-driven interactive move | No reliable global top-level position; GTK reports `(0, 0)` | The compositor owns the move and the surface loses pointer focus | No portable absolute top-level positioning | Not supportable as specified |

## Documented facts

### Current Flutter and `window_manager` surface

The project uses `window_manager` 0.5.1. Its `WindowListener` exposes
`onWindowMove`, while `onWindowMoved` is explicitly documented for macOS and
Windows only. The same API exposes `getPosition`, `setPosition`, and
`setBounds(..., animate: ...)`.

Sources:

- [`window_manager` 0.5.1 package page](https://pub.dev/packages/window_manager/versions/0.5.1)
- [`WindowListener` at the 0.5.1 source commit](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/lib/src/window_listener.dart#L1-L42)
- [`getPosition`, `setPosition`, and `setBounds`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/lib/src/window_manager.dart#L359-L423)

`DragToMoveArea` does not implement a Flutter-side drag trajectory. Its
`onPanStart` immediately calls `windowManager.startDragging()`, which hands the
operation to the platform implementation.

Source: [`DragToMoveArea` implementation](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/lib/src/widgets/drag_to_move_area.dart#L22-L44)

Flutter itself can generate physics values. `AnimationController.animateWith`
drives an animation from a `Simulation`; Flutter supplies spring and friction
simulations. These are numeric/UI animation facilities, not top-level window
management facilities.

Sources:

- [Flutter `AnimationController.animateWith`](https://api.flutter.dev/flutter/animation/AnimationController/animateWith.html)
- [Flutter physics library](https://api.flutter.dev/flutter/physics/)
- [Flutter `SpringSimulation`](https://api.flutter.dev/flutter/physics/SpringSimulation-class.html)

### Windows

The Windows implementation preserves native moving by releasing capture and
sending `WM_SYSCOMMAND` with `SC_MOVE | HTCAPTION`.

Source: [`window_manager` Windows `StartDragging`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/windows/window_manager.cpp#L1091-L1095)

Windows sends `WM_MOVING` while the user moves a window. Microsoft documents
that the message carries a `RECT` containing the current window position in
screen coordinates. Windows sends `WM_EXITSIZEMOVE` once after the window exits
the native moving or sizing modal loop.

Sources:

- [Microsoft `WM_MOVING`](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-moving)
- [Microsoft `WM_EXITSIZEMOVE`](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-exitsizemove)

`window_manager` 0.5.1 already converts `WM_MOVING` to its `move` event and
`WM_EXITSIZEMOVE` to its `moved` event. This provides a clear release boundary
on Windows.

Source: [`window_manager` Windows message handling](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/windows/window_manager_plugin.cpp#L216-L231)

The plugin moves a window with `SetWindowPos`. Microsoft documents
`SetWindowPos` as changing a top-level window's position, size, and Z order.
The 0.5.1 Windows implementation does not read the Dart `animate` argument, so
`setPosition(..., animate: true)` does not provide a native Windows landing
animation.

Sources:

- [Microsoft `SetWindowPos`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos)
- [`window_manager` Windows `SetBounds`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/windows/window_manager.cpp#L742-L774)

### macOS

The macOS implementation calls `NSWindow.performDrag(with:)`. Apple documents
that this hands the drag to Window Server so it participates in system features
such as Space switching. Apple also explicitly states that the method returns
right away and that a mouse-up event may not be sent.

Sources:

- [Apple `NSWindow.performDrag(with:)`](https://developer.apple.com/documentation/appkit/nswindow/performdrag%28with%3A%29)
- [`window_manager` macOS `startDragging`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/macos/window_manager/Sources/window_manager/WindowManager.swift#L513-L521)

AppKit supplies `windowWillMove` and `windowDidMove`, but its delegate API has
no counterpart to `windowDidEndLiveResize` for a completed move. In
`window_manager` 0.5.1, `windowWillMove` emits `move` and each `windowDidMove`
notification emits `moved`. Consequently, the plugin's `moved` event is not a
documented mouse-release boundary for an AppKit drag.

Sources:

- [Apple `NSWindowDelegate`](https://developer.apple.com/documentation/appkit/nswindowdelegate)
- [Apple `windowDidMove(_:)`](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidmove%28_%3A%29)
- [`window_manager` macOS delegate mapping](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/macos/window_manager/Sources/window_manager/WindowManager.swift#L552-L563)

The macOS implementation is the only one of the three that consumes
`animate: true`: it uses AppKit's window animator and `setFrame`. Apple
documents this built-in option as a smooth frame resize whose duration is
controlled by AppKit. It does not accept a release velocity or custom spring.

Sources:

- [`window_manager` macOS `setBounds`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/macos/window_manager/Sources/window_manager/WindowManager.swift#L263-L292)
- [Apple `setFrame(_:display:animate:)`](https://developer.apple.com/documentation/appkit/nswindow/setframe%28_%3Adisplay%3Aanimate%3A%29)

### Linux with GTK and X11

The Linux implementation calls `gtk_window_begin_move_drag`, which GTK
documents as using the standard window-manager or windowing-system move
mechanism where supported, and otherwise emulating it with potentially uneven
results.

Sources:

- [`window_manager` Linux `start_dragging`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/linux/window_manager_plugin.cc#L611-L632)
- [GTK 3 `Window.begin_move_drag`](https://docs.gtk.org/gtk3/method.Window.begin_move_drag.html)

GTK's `configure-event` reports changes to size, position, or stacking. The
plugin connects that signal to a generic `move` event, but the Dart API does not
offer `onWindowMoved` on Linux.

Sources:

- [GTK 3 `Widget::configure-event`](https://docs.gtk.org/gtk3/signal.Widget.configure-event.html)
- [`window_manager` Linux event setup and `on_window_move`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/linux/window_manager_plugin.cc#L1004-L1122)
- [`window_manager` platform annotation for `onWindowMoved`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/lib/src/window_listener.dart#L27-L37)

For programmatic movement, `window_manager` calls `gtk_window_move` and ignores
the `animate` argument. GTK describes this as a request to the window manager
and states that window managers are free to ignore it.

Sources:

- [`window_manager` Linux `set_bounds`](https://github.com/leanflutter/window_manager/blob/48bf2ea/packages/window_manager/linux/window_manager_plugin.cc#L276-L296)
- [GTK 3 `Window.move`](https://docs.gtk.org/gtk3/method.Window.move.html)

### Linux with Wayland

GTK documents that some windowing systems, including Wayland, do not provide a
global coordinate system. `gtk_window_get_position` therefore always returns
`(0, 0)` on those systems.

Source: [GTK 3 `Window.get_position`](https://docs.gtk.org/gtk3/method.Window.get_position.html)

The stable XDG shell protocol defines top-level movement as an interactive,
user-driven request to the compositor. The compositor may ignore it. Once the
move begins, the surface loses the pointer or touch focus used to initiate it,
and focus is not guaranteed to return after completion. The protocol does not
provide a request for a client to assign an arbitrary global position to an
`xdg_toplevel`.

Source: [freedesktop.org XDG shell protocol](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/stable/xdg-shell/xdg-shell.xml)

### `motor`

The package describes itself as a unified Flutter motion system. It can animate
complex values such as `Offset`, simulate independent dimensions, and preserve
velocity when a target changes. Its builders and controllers animate Flutter
values and widgets. Its documented API contains no operating-system window
position primitive.

Sources:

- [`motor` package documentation](https://pub.dev/packages/motor)
- [`motor` API documentation](https://pub.dev/documentation/motor/latest/)

## Engineering inferences

The following conclusions are engineering judgments derived from the APIs
above, not guarantees made by their vendors.

### Windows: high-confidence prototype

A native Windows implementation could timestamp successive `WM_MOVING`
rectangles, calculate a two-dimensional release velocity, and begin landing on
`WM_EXITSIZEMOVE`. It could then submit only changing `(x, y)` origins with
`SetWindowPos`, clamped to the active monitor's work area. This preserves the
PiP size and therefore does not alter its board aspect ratio or crop its
contents.

Sampling via native `WM_MOVING` data is likely to be more stable than reacting
to a Dart `move` callback and performing an asynchronous `getPosition` method
call for every sample. A production implementation should also cancel the
landing immediately when a new drag starts.

### macOS: possible, but release detection must be proven

Position animation is possible, but the existing plugin does not expose an
unambiguous native drag completion or release velocity. A custom macOS bridge
would need to detect the end of the Window Server-owned operation, likely via
additional event monitoring or a carefully tested movement-settled heuristic.
Apple's warning that mouse-up may not arrive rules out assuming an ordinary
Flutter `onPanEnd` is authoritative.

The existing `animate: true` flag could create a simple fixed AppKit settle, but
it is not a velocity-preserving throw or tunable spring. Custom physics would
still require a stream of position updates.

### Linux/X11: best-effort only

An X11 session could estimate velocity from configure events and infer the end
of movement from a native button release or a short quiet period. Both release
detection and requested landing positions can vary by window manager, so this
would require a support matrix rather than a blanket Linux guarantee.

### Linux/Wayland: no portable implementation

Without a global position, the app cannot calculate its distance to a screen
edge, choose a global corner, or verify a sequence of requested positions.
Because the compositor owns the interactive move, Flutter-side physics cannot
take over the top-level window trajectory in a portable Wayland application.
Compositor-specific protocols, forcing an X11/XWayland backend, or changing the
feature into an in-app floating widget would be materially different designs.

### Role of `motor`

If a Windows/macOS-only prototype were approved, `motor` could be used as a
numeric two-dimensional spring controller. Each tick would still call a native
window-position operation. Flutter's built-in `SpringSimulation`,
`FrictionSimulation`, and `AnimationController.animateWith` can already fill
that numerical role, so `motor` is optional rather than enabling technology.

## Recommendation

Keep the current native drag on every platform. Do not promise a cross-platform
throw interaction.

If the interaction is still desirable, first build a disposable Windows-only
prototype and measure frame pacing, release velocity quality, monitor-edge
clamping, DPI transitions, and interruption by a new drag. Only then evaluate a
separate macOS native release detector. Leave Linux/Wayland on normal native
drag unless the product explicitly accepts different platform behavior.
