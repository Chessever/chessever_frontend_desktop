import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/shell/desktop_chrome_metrics.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

/// Width reserved at the right edge of title-bar surfaces for the three
/// Windows/Linux caption controls.
const double kDesktopWindowControlsWidth = 138;

bool get _usesCustomWindowControls => Platform.isWindows || Platform.isLinux;

/// Supplies the virtual resize frame required by hidden-title-bar windows and
/// keeps Windows/Linux caption controls available above every desktop route.
///
/// macOS intentionally renders no Flutter caption buttons here. Its native
/// traffic lights remain visible over the Flutter-painted title-bar surface.
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame>
    with WindowListener {
  bool _isMaximized = false;
  bool _actionPending = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_refreshMaximizedState());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshMaximizedState() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted && maximized != _isMaximized) {
        setState(() => _isMaximized = maximized);
      }
    } catch (_) {
      // Window chrome must remain usable even when the platform channel is
      // temporarily unavailable during startup or shutdown.
    }
  }

  Future<void> _runWindowAction(Future<void> Function() action) async {
    if (_actionPending) return;
    _actionPending = true;
    try {
      await action();
    } catch (_) {
      // A native window can disappear between pointer-down and command
      // dispatch. Leave the rest of the shell mounted in that race.
    } finally {
      _actionPending = false;
    }
  }

  Future<void> _toggleMaximized() async {
    await _runWindowAction(() async {
      final maximized = await windowManager.isMaximized();
      if (maximized) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    });
    await _refreshMaximizedState();
  }

  @override
  Widget build(BuildContext context) {
    return VirtualWindowFrame(
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_usesCustomWindowControls)
            Positioned(
              top: 0,
              right: 0,
              width: kDesktopWindowControlsWidth,
              height: kDesktopChromeBarHeight,
              // Isolate the caption strip's raster from the heavy shell
              // repainting behind it so a partial repaint of the pane can never
              // bleed a stale frame into the window controls.
              child: RepaintBoundary(
                child: _DesktopWindowControls(
                  isMaximized: _isMaximized,
                  onMinimize: () => _runWindowAction(windowManager.minimize),
                  onToggleMaximized: _toggleMaximized,
                  onClose: () => _runWindowAction(windowManager.close),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  void onWindowRestore() {
    unawaited(_refreshMaximizedState());
  }
}

/// A quiet title-bar row for desktop routes that do not render the persistent
/// shell, such as sign-in, subscription gating, and detached board windows.
class DesktopStandaloneWindowChrome extends StatelessWidget {
  const DesktopStandaloneWindowChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBackgroundColor,
      child: Column(
        children: [
          SizedBox(
            height: kDesktopChromeBarHeight,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: kBlack2Color,
                border: Border(
                  bottom: BorderSide(color: kDividerColor, width: 1),
                ),
              ),
              child: Row(
                children: [
                  if (Platform.isMacOS) const SizedBox(width: 78),
                  const Expanded(
                    child: DragToMoveArea(child: SizedBox.expand()),
                  ),
                  if (_usesCustomWindowControls)
                    const SizedBox(width: kDesktopWindowControlsWidth),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _DesktopWindowControls extends StatelessWidget {
  const _DesktopWindowControls({
    required this.isMaximized,
    required this.onMinimize,
    required this.onToggleMaximized,
    required this.onClose,
  });

  final bool isMaximized;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximized;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBlack2Color,
      child: Row(
        children: [
          _DesktopCaptionButton(
            tooltip: 'Minimize',
            semanticLabel: 'Minimize window',
            icon: const DesktopCaptionGlyph(DesktopCaptionGlyphType.minimize),
            onTap: onMinimize,
          ),
          _DesktopCaptionButton(
            tooltip: isMaximized ? 'Restore' : 'Maximize',
            semanticLabel: isMaximized ? 'Restore window' : 'Maximize window',
            icon: DesktopCaptionGlyph(
              isMaximized
                  ? DesktopCaptionGlyphType.restore
                  : DesktopCaptionGlyphType.maximize,
            ),
            onTap: onToggleMaximized,
          ),
          _DesktopCaptionButton(
            tooltip: 'Close',
            semanticLabel: 'Close window',
            icon: const DesktopCaptionGlyph(DesktopCaptionGlyphType.close),
            onTap: onClose,
            destructive: true,
          ),
        ],
      ),
    );
  }
}

class _DesktopCaptionButton extends StatefulWidget {
  const _DesktopCaptionButton({
    required this.tooltip,
    required this.semanticLabel,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  final String tooltip;
  final String semanticLabel;
  final Widget icon;
  final VoidCallback onTap;
  final bool destructive;

  @override
  State<_DesktopCaptionButton> createState() => _DesktopCaptionButtonState();
}

class _DesktopCaptionButtonState extends State<_DesktopCaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // Opaque fills only — never `Colors.transparent`, never an implicit fade.
    //
    // The caption strip sits over the Windows client edge of a hidden-native-
    // title-bar window. A semi-transparent or animated fill can freeze on a
    // mid-blend frame when the engine stops pumping frames (window occluded or
    // blurred on alt-tab / focus loss, which is constant on Windows), leaving a
    // muddy grey box where the close glyph should be — reported as "the X turns
    // grey". Solid colours give every state a fully defined, deterministic
    // frame, so nothing can be left half-composited. The close button is the
    // only one this ever showed on because its hover fill (red) is the only
    // strongly opaque one; the resting fill matches the strip so the swap is
    // seamless. Values below are the old translucent overlays pre-blended over
    // `kBlack2Color` so the look is unchanged.
    final Color background;
    if (widget.destructive) {
      background =
          _pressed
              ? const Color(0xFFC70F20)
              : _hovered
              ? const Color(0xFFE81123)
              : kBlack2Color;
    } else {
      background =
          _pressed
              ? const Color(0xFF353537) // kWhiteColor @12% over kBlack2Color
              : _hovered
              ? const Color(0xFF2A2A2C) // kWhiteColor @7% over kBlack2Color
              : kBlack2Color;
    }
    final foreground =
        widget.destructive && (_hovered || _pressed)
            ? kWhiteColor
            : (_hovered ? kWhiteColor : kWhiteColor70);

    return Expanded(
      child: DesktopTooltip(
        message: widget.tooltip,
        child: Semantics(
          button: true,
          label: widget.semanticLabel,
          child: ClickCursor(
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit:
                  (_) => setState(() {
                    _hovered = false;
                    _pressed = false;
                  }),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                onTapDown: (_) => setState(() => _pressed = true),
                onTapUp: (_) => setState(() => _pressed = false),
                onTapCancel: () => setState(() => _pressed = false),
                // Not AnimatedContainer: the hover/press swap is instant so no
                // in-flight colour tween can be frozen mid-blend by a window
                // occlusion. Native Windows caption buttons snap instantly too.
                child: Container(
                  color: background,
                  alignment: Alignment.center,
                  child: IconTheme(
                    data: IconThemeData(color: foreground, size: 14),
                    child: widget.icon,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glyphs used by the custom Windows/Linux caption controls.
enum DesktopCaptionGlyphType { minimize, maximize, restore, close }

/// A caption glyph backed by Flutter's bundled Material icon font.
///
/// Do not replace these with thin, fractionally positioned `CustomPaint`
/// strokes. Those strokes can disappear under Windows ANGLE, particularly at
/// non-integer display scale factors. The font glyphs are filled paths and
/// remain visible across Windows DPI and graphics-driver combinations while
/// the surrounding controls retain the app's custom title-bar styling.
class DesktopCaptionGlyph extends StatelessWidget {
  const DesktopCaptionGlyph(this.type, {super.key});

  final DesktopCaptionGlyphType type;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, double size) = switch (type) {
      DesktopCaptionGlyphType.minimize => (Icons.remove_rounded, 16),
      DesktopCaptionGlyphType.maximize => (Icons.crop_square_rounded, 16),
      DesktopCaptionGlyphType.restore => (Icons.filter_none_rounded, 15),
      DesktopCaptionGlyphType.close => (Icons.close_rounded, 17),
    };
    return Icon(icon, size: size);
  }
}
