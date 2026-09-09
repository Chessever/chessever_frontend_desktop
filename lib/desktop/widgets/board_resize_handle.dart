import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

/// Edge length of the square grip painted at the board's bottom-right corner.
/// Panes reserve this much trailing space inside their player rows so the grip
/// never lands on top of a clock or a name.
const double kDesktopBoardResizeHandleSize = 22.0;

/// Shared board-size bounds. Watching (Board pane) and playing (Play pane)
/// use the same range so a board feels the same size in both places.
const double kDesktopBoardMinSize = 300.0;
const double kDesktopBoardMaxSize = 1200.0;
const double kDesktopBoardDefaultSize = 760.0;

/// Converts a corner-grip drag offset into a single board-size delta.
double desktopBoardResizeDragDelta(Offset offset) {
  // Use the dominant magnitude for the bottom-right grip. When axes disagree
  // (right+up or left+down), horizontal intent wins so rightward grow-drags
  // cannot be cancelled by upward pointer drift.
  if (offset.dx == 0) return offset.dy;
  if (offset.dy == 0) return offset.dx;
  final magnitude = math.max(offset.dx.abs(), offset.dy.abs());
  final horizontalSign = offset.dx.isNegative ? -1.0 : 1.0;
  if (offset.dx.isNegative != offset.dy.isNegative) {
    return magnitude * horizontalSign;
  }
  return magnitude * (offset.dy.isNegative ? -1.0 : 1.0);
}

/// Corner grip that resizes a chessboard by dragging, and restores the
/// default size on double-click.
class BoardResizeHandle extends StatefulWidget {
  const BoardResizeHandle({
    super.key,
    required this.boardSize,
    required this.minSize,
    required this.maxSize,
    required this.onResize,
    required this.onResizeEnd,
    required this.onReset,
  });

  final double boardSize;
  final double minSize;
  final double maxSize;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback onReset;

  @override
  State<BoardResizeHandle> createState() => _BoardResizeHandleState();
}

class _BoardResizeHandleState extends State<BoardResizeHandle> {
  Offset? _dragStart;
  double? _sizeStart;
  bool _active = false;

  void _begin(DragStartDetails details) {
    _dragStart = details.globalPosition;
    _sizeStart = widget.boardSize;
    setState(() => _active = true);
  }

  void _update(DragUpdateDetails details) {
    final start = _dragStart;
    final sizeStart = _sizeStart;
    if (start == null || sizeStart == null) return;
    final offset = details.globalPosition - start;
    final delta = desktopBoardResizeDragDelta(offset);
    final rawSize = sizeStart + delta;
    widget.onResize(rawSize.clamp(widget.minSize, widget.maxSize).toDouble());
  }

  void _end() {
    if (!_active) return;
    _dragStart = null;
    _sizeStart = null;
    setState(() => _active = false);
    widget.onResizeEnd();
  }

  @override
  Widget build(BuildContext context) {
    final handle = MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: _begin,
        onPanUpdate: _update,
        onPanEnd: (_) => _end(),
        onPanCancel: _end,
        onDoubleTap: widget.onReset,
        child: AnimatedContainer(
          key: const ValueKey<String>('desktop-board-resize-handle'),
          duration: const Duration(milliseconds: 120),
          width: kDesktopBoardResizeHandleSize,
          height: kDesktopBoardResizeHandleSize,
          decoration: BoxDecoration(
            color:
                _active
                    ? kPrimaryColor.withValues(alpha: 0.94)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _active ? kPrimaryColor : Colors.transparent,
            ),
            boxShadow:
                _active
                    ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                    : null,
          ),
          child: CustomPaint(
            painter: _ResizeGripPainter(
              color: _active ? kBackgroundColor : kWhiteColor70,
            ),
          ),
        ),
      ),
    );
    return DesktopTooltip(
      message: 'Drag to resize board. Double-click to reset.',
      child: handle,
    );
  }
}

class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color.withValues(alpha: 0.82)
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round;
    for (final inset in <double>[7, 11, 15]) {
      canvas.drawLine(
        Offset(size.width - inset, size.height - 4),
        Offset(size.width - 4, size.height - inset),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeGripPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
