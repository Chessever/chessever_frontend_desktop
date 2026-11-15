import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/theme/app_theme.dart';

/// Makes a game row draggable onto the tab strip or the Board workspace,
/// where the drop opens it beside the board being viewed.
///
/// A mouse picks the row up after a short deliberate travel, so a click
/// with a little jitter still selects or opens the row the way it always
/// did. A finger has to rest on the row first, so scrolling a list by touch
/// never starts a drag.
///
/// The feedback is anchored at the pointer (`pointerDragAnchorStrategy`):
/// drop targets read the pointer position straight from the drag offset.
class GameDragSource extends Draggable<GameTabDragPayload> {
  GameDragSource({
    super.key,
    required GameTabDragPayload payload,
    required super.child,
  }) : super(
         data: payload,
         maxSimultaneousDrags: 1,
         dragAnchorStrategy: pointerDragAnchorStrategy,
         feedback: GameDragChip(label: payload.label),
       );

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      DeliberateMultiDragGestureRecognizer(debugOwner: this)..onStart = onStart;
}

/// Starts a drag only on deliberate travel (mouse, trackpad, stylus) or
/// after a finger rests in place ([touchHoldDelay]).
class DeliberateMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  DeliberateMultiDragGestureRecognizer({
    super.debugOwner,
    this.travel = kTouchSlop,
    this.touchHoldDelay = const Duration(milliseconds: 300),
  });

  /// Distance a precise pointer must travel before the drag starts. The
  /// touch slop, so whatever Flutter still calls a tap stays a tap.
  final double travel;

  /// How long a finger must rest on the row before it can drag it.
  final Duration touchHoldDelay;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      return _HoldPointerState(
        event.position,
        event.kind,
        gestureSettings,
        touchHoldDelay,
      );
    }
    return _TravelPointerState(
      event.position,
      event.kind,
      gestureSettings,
      travel,
    );
  }

  @override
  String get debugDescription => 'deliberate game drag';
}

class _TravelPointerState extends MultiDragPointerState {
  _TravelPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
    this._travel,
  );

  final double _travel;
  GestureMultiDragStartCallback? _starter;

  bool get _travelled =>
      pendingDelta!.distance >
      math.max(_travel, computeHitSlop(kind, gestureSettings));

  @override
  void checkForResolutionAfterMove() {
    if (!_travelled) return;
    final starter = _starter;
    if (starter != null) {
      _starter = null;
      starter(initialPosition);
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    // Alone in the arena, this state wins on pointer-down. Winning is not
    // drag intent: wait for the travel before lifting the row.
    if (_travelled) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void dispose() {
    _starter = null;
    super.dispose();
  }
}

class _HoldPointerState extends MultiDragPointerState {
  _HoldPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
    Duration delay,
  ) {
    _timer = Timer(delay, _held);
  }

  Timer? _timer;
  GestureMultiDragStartCallback? _starter;

  void _held() {
    _timer = null;
    final starter = _starter;
    if (starter != null) {
      _starter = null;
      starter(initialPosition);
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void checkForResolutionAfterMove() {
    // Moving before the hold is a scroll, not a drag.
    if (_timer != null &&
        pendingDelta!.distance > computeHitSlop(kind, gestureSettings)) {
      resolve(GestureDisposition.rejected);
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    if (_timer == null) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _starter = null;
    super.dispose();
  }
}

/// The small chip that follows the pointer while a game is dragged.
class GameDragChip extends StatelessWidget {
  const GameDragChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Transform.translate(
        // Sit just below-right of the cursor so the pointer tip and the
        // drop preview under it stay visible.
        offset: const Offset(14, 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack3Color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kWhiteColor.withValues(alpha: 0.10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.32),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _MiniBoardGlyph(),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 2x2 board corner: says "a game" without borrowing a stock icon.
class _MiniBoardGlyph extends StatelessWidget {
  const _MiniBoardGlyph();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 12,
      child: CustomPaint(painter: _MiniBoardPainter()),
    );
  }
}

class _MiniBoardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;
    final light = Paint()..color = kWhiteColor.withValues(alpha: 0.82);
    final dark = Paint()..color = kWhiteColor.withValues(alpha: 0.28);
    final r = const Radius.circular(1.5);
    canvas
      ..drawRRect(
        RRect.fromRectAndCorners(Rect.fromLTWH(0, 0, half, half), topLeft: r),
        light,
      )
      ..drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(half, 0, half, half),
          topRight: r,
        ),
        dark,
      )
      ..drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(0, half, half, half),
          bottomLeft: r,
        ),
        dark,
      )
      ..drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(half, half, half, half),
          bottomRight: r,
        ),
        light,
      );
  }

  @override
  bool shouldRepaint(_MiniBoardPainter oldDelegate) => false;
}
