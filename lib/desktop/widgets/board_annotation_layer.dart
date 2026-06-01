import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_annotations.dart';

/// Captures secondary-button (right-click) gestures over the chessboard and
/// converts them into circles / arrows on
/// [boardAnnotationsProvider].
///
/// Plain right-click is reserved for the board's context menu (handled by the
/// GestureDetector around `_BoardArea`), but plain right-drag draws a green
/// arrow. Holding Shift / Alt / Ctrl / Cmd opts into annotation mode
/// immediately, so modifier right-clicks can still plant circles.
///
/// Behaviour:
///  - Plain right-click                  → board context menu
///  - Plain right-click + drag           → finalize a green arrow A → B
///  - Modifier + right-click a square    → toggle a circle on that square
///  - Modifier + right-click + drag      → finalize an arrow A → B
///  - Shift / Alt / Ctrl-Cmd modifiers   → red / blue / yellow variants
///  - Plain left-click on the board      → wipe all shapes
///
/// The overlay sits *on top* of the board widget but is transparent and
/// only intercepts events when its gate conditions are met; left-click
/// pieces still go straight to chessground.
class BoardAnnotationLayer extends ConsumerStatefulWidget {
  const BoardAnnotationLayer({
    super.key,
    required this.tabId,
    required this.size,
    required this.orientation,
    required this.child,
    this.onLeftClickClear,
  });

  /// Edge length of the visible chessboard in logical px.
  final String tabId;
  final double size;
  final Side orientation;
  final Widget child;

  /// Called when the user left-clicks anywhere on the board *and* there
  /// were drawn shapes to clear. Useful if the host wants a haptic /
  /// undo-stack trigger on top of the wipe.
  final VoidCallback? onLeftClickClear;

  @override
  ConsumerState<BoardAnnotationLayer> createState() =>
      _BoardAnnotationLayerState();
}

class _BoardAnnotationLayerState extends ConsumerState<BoardAnnotationLayer> {
  static const double _plainDragThreshold = 4.0;

  Square? _origSquare;
  Square? _hoverSquare;
  AnnotationColor _activeColor = AnnotationColor.green;
  Offset? _liveCursor;
  Offset? _downLocal;
  bool _plainSecondaryGesture = false;
  bool _secondaryDragStarted = false;

  Square? _squareAt(Offset local) {
    if (local.dx < 0 || local.dy < 0) return null;
    if (local.dx >= widget.size || local.dy >= widget.size) return null;
    final squareSize = widget.size / 8;
    final x = (local.dx / squareSize).floor();
    final y = (local.dy / squareSize).floor();
    final ox = widget.orientation == Side.black ? 7 - x : x;
    final oy = widget.orientation == Side.black ? y : 7 - y;
    if (ox < 0 || ox > 7 || oy < 0 || oy > 7) return null;
    return Square.fromCoords(File(ox), Rank(oy));
  }

  bool _hasAnnotationModifierHeld() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight) ||
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
  }

  AnnotationColor _colorForCurrentModifiers() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final shift =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    final alt =
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight);
    final ctrl =
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
    return pickAnnotationColor(shift: shift, alt: alt, ctrl: ctrl);
  }

  @override
  Widget build(BuildContext context) {
    final tabId = widget.tabId;
    return Listener(
      // Use Listener so we can branch on PointerDownEvent.buttons (left vs
      // right) without the GestureRecognizer system fighting chessground
      // for the primary button.
      onPointerDown: (event) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(event.position);
        if (event.buttons & kSecondaryMouseButton != 0) {
          final sq = _squareAt(local);
          if (sq == null) return;
          final hasModifier = _hasAnnotationModifierHeld();
          setState(() {
            _origSquare = sq;
            _hoverSquare = sq;
            _activeColor = _colorForCurrentModifiers();
            _liveCursor = hasModifier ? local : null;
            _downLocal = local;
            _plainSecondaryGesture = !hasModifier;
            _secondaryDragStarted = false;
          });
        } else if (event.buttons & kPrimaryMouseButton != 0) {
          // Left-click — if shapes exist, wipe them. We deliberately do
          // not consume the event; chessground handles primary-button
          // selection underneath this Listener.
          final notifier = ref.read(boardAnnotationsProvider(tabId).notifier);
          final hasShapes =
              ref.read(boardAnnotationsProvider(tabId)).shapes.isNotEmpty;
          if (hasShapes) {
            notifier.clear();
            widget.onLeftClickClear?.call();
          }
        }
      },
      onPointerMove: (event) {
        if (_origSquare == null) return;
        if (event.buttons & kSecondaryMouseButton == 0) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(event.position);
        final sq = _squareAt(local);
        final dragStarted =
            _secondaryDragStarted ||
            sq != _origSquare ||
            (_downLocal != null &&
                (local - _downLocal!).distance >= _plainDragThreshold);
        if (sq != _hoverSquare ||
            local != _liveCursor ||
            dragStarted != _secondaryDragStarted) {
          setState(() {
            _hoverSquare = sq;
            _liveCursor = local;
            _secondaryDragStarted = dragStarted;
          });
        }
      },
      onPointerUp: (event) {
        if (_origSquare == null) return;
        final notifier = ref.read(boardAnnotationsProvider(tabId).notifier);
        final orig = _origSquare!;
        final dest = _hoverSquare ?? orig;
        final plainArrowDest =
            _plainSecondaryGesture && _hoverSquare != null && dest != orig;
        final shouldCommit = !_plainSecondaryGesture || plainArrowDest;
        if (shouldCommit) {
          if (orig == dest) {
            notifier.toggleCircle(orig, _activeColor);
          } else {
            notifier.toggleArrow(orig, dest, _activeColor);
          }
        }
        _resetGestureState();
      },
      onPointerCancel: (_) => _resetGestureState(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_origSquare != null &&
              _hoverSquare != null &&
              (!_plainSecondaryGesture || _hoverSquare != _origSquare))
            // In-flight preview — we paint a translucent ghost arrow / ring
            // on top of the board so the user sees what they're drawing
            // before lifting the right mouse button.
            IgnorePointer(
              child: CustomPaint(
                painter: _InFlightShapePainter(
                  size: widget.size,
                  orientation: widget.orientation,
                  orig: _origSquare!,
                  dest: _hoverSquare!,
                  color: _activeColor.color,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _resetGestureState() {
    setState(() {
      _origSquare = null;
      _hoverSquare = null;
      _liveCursor = null;
      _downLocal = null;
      _plainSecondaryGesture = false;
      _secondaryDragStarted = false;
    });
  }
}

class _InFlightShapePainter extends CustomPainter {
  _InFlightShapePainter({
    required this.size,
    required this.orientation,
    required this.orig,
    required this.dest,
    required this.color,
  });

  final double size;
  final Side orientation;
  final Square orig;
  final Square dest;
  final Color color;

  Offset _centerOf(Square s) {
    final squareSize = size / 8;
    final x = orientation == Side.black ? 7 - s.file : s.file;
    final y = orientation == Side.black ? s.rank : 7 - s.rank;
    return Offset((x + 0.5) * squareSize, (y + 0.5) * squareSize);
  }

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final squareSize = size / 8;
    final paint =
        Paint()
          ..color = color.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke;

    if (orig == dest) {
      // Draw a translucent ring on the origin square — the "I will plant
      // a circle here on release" hint.
      final c = _centerOf(orig);
      paint.strokeWidth = squareSize * 1 / 16;
      canvas.drawCircle(c, squareSize * 0.45, paint);
      return;
    }

    // Live arrow preview — same geometry chessground uses for finalised
    // arrows so the in-flight ghost matches the landed shape exactly.
    final fromCenter = _centerOf(orig);
    final toCenter = _centerOf(dest);
    final delta = toCenter - fromCenter;
    final unit = delta / delta.distance;
    final perp = Offset(-unit.dy, unit.dx);
    final lineWidth = squareSize / 4 * 0.55;
    final headSize = squareSize / 3;
    final shaftEnd = toCenter - unit * headSize;

    paint
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.55);

    final shaft =
        Path()
          ..moveTo(
            fromCenter.dx + perp.dx * lineWidth / 2,
            fromCenter.dy + perp.dy * lineWidth / 2,
          )
          ..lineTo(
            shaftEnd.dx + perp.dx * lineWidth / 2,
            shaftEnd.dy + perp.dy * lineWidth / 2,
          )
          ..lineTo(
            shaftEnd.dx - perp.dx * lineWidth / 2,
            shaftEnd.dy - perp.dy * lineWidth / 2,
          )
          ..lineTo(
            fromCenter.dx - perp.dx * lineWidth / 2,
            fromCenter.dy - perp.dy * lineWidth / 2,
          )
          ..close();
    canvas.drawPath(shaft, paint);

    final head =
        Path()
          ..moveTo(toCenter.dx, toCenter.dy)
          ..lineTo(
            shaftEnd.dx + perp.dx * headSize / 2,
            shaftEnd.dy + perp.dy * headSize / 2,
          )
          ..lineTo(
            shaftEnd.dx - perp.dx * headSize / 2,
            shaftEnd.dy - perp.dy * headSize / 2,
          )
          ..close();
    canvas.drawPath(head, paint);
  }

  @override
  bool shouldRepaint(covariant _InFlightShapePainter old) {
    return old.orig != orig ||
        old.dest != dest ||
        old.color != color ||
        old.size != size ||
        old.orientation != orientation;
  }
}
