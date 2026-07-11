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
              child: _DesktopWindowControls(
                isMaximized: _isMaximized,
                onMinimize: () => _runWindowAction(windowManager.minimize),
                onToggleMaximized: _toggleMaximized,
                onClose: () => _runWindowAction(windowManager.close),
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
            icon: const _MinimizeGlyph(),
            onTap: onMinimize,
          ),
          _DesktopCaptionButton(
            tooltip: isMaximized ? 'Restore' : 'Maximize',
            semanticLabel: isMaximized ? 'Restore window' : 'Maximize window',
            icon: isMaximized ? const _RestoreGlyph() : const _MaximizeGlyph(),
            onTap: onToggleMaximized,
          ),
          _DesktopCaptionButton(
            tooltip: 'Close',
            semanticLabel: 'Close window',
            icon: const _CloseGlyph(),
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
    final background =
        _pressed
            ? (widget.destructive
                ? const Color(0xFFC70F20)
                : kWhiteColor.withValues(alpha: 0.12))
            : _hovered
            ? (widget.destructive
                ? const Color(0xFFE81123)
                : kWhiteColor.withValues(alpha: 0.07))
            : Colors.transparent;
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
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
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

class _MinimizeGlyph extends StatelessWidget {
  const _MinimizeGlyph();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(12, 10),
      painter: _CaptionGlyphPainter(color: IconTheme.of(context).color!),
    );
  }
}

class _MaximizeGlyph extends StatelessWidget {
  const _MaximizeGlyph();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(12, 12),
      painter: _CaptionGlyphPainter(
        color: IconTheme.of(context).color!,
        maximize: true,
      ),
    );
  }
}

class _RestoreGlyph extends StatelessWidget {
  const _RestoreGlyph();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(13, 13),
      painter: _CaptionGlyphPainter(
        color: IconTheme.of(context).color!,
        restore: true,
      ),
    );
  }
}

class _CloseGlyph extends StatelessWidget {
  const _CloseGlyph();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(12, 12),
      painter: _CaptionGlyphPainter(
        color: IconTheme.of(context).color!,
        close: true,
      ),
    );
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  _CaptionGlyphPainter({
    required this.color,
    this.maximize = false,
    this.restore = false,
    this.close = false,
  });

  final Color color;
  final bool maximize;
  final bool restore;
  final bool close;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.15;
    if (close) {
      canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
      canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
      return;
    }
    if (restore) {
      canvas.drawRect(
        Rect.fromLTWH(3.5, 0.5, size.width - 4, size.height - 4),
        paint,
      );
      canvas.drawRect(
        Rect.fromLTWH(0.5, 3.5, size.width - 4, size.height - 4),
        paint,
      );
      return;
    }
    if (maximize) {
      canvas.drawRect(
        Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
        paint,
      );
      return;
    }
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CaptionGlyphPainter oldDelegate) =>
      color != oldDelegate.color ||
      maximize != oldDelegate.maximize ||
      restore != oldDelegate.restore ||
      close != oldDelegate.close;
}
