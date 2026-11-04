import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/likes/community_likes_models.dart'
    show compactLikeCount, communityLikesLabel;

/// Sets a like count on the top-left corner of every game-card board below
/// it, the phone's `BoardCornerBadge`. The Likes ranking wraps each card in
/// one so the board itself carries the number the list is ranked by.
///
/// Holds the count, not a builder, so a memoized card only rebuilds its
/// board when the count actually changes.
class DesktopBoardLikeBadge extends InheritedWidget {
  const DesktopBoardLikeBadge({
    super.key,
    required this.likes,
    required super.child,
  });

  final int likes;

  static int? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DesktopBoardLikeBadge>()
          ?.likes;

  @override
  bool updateShouldNotify(DesktopBoardLikeBadge oldWidget) =>
      oldWidget.likes != likes;
}

/// The heart's width on a board [boardSize] across: about a square and a
/// quarter, never so small the count blurs nor so big it hides the game.
double desktopLikeHeartSizeFor(double boardSize) =>
    (boardSize * 0.16).clamp(30.0, 52.0);

/// A heart holding a like count, to sit on a board: a solid dark heart (the
/// piece under it never shows through) with the count in white, fitted in
/// the heart's round upper body. The same figure as the phone's.
class DesktopLikeCountHeart extends StatelessWidget {
  const DesktopLikeCountHeart({
    super.key,
    required this.likes,
    required this.size,
  });

  final int likes;

  /// The heart's width; its height is 0.9 of it.
  final double size;

  @override
  Widget build(BuildContext context) {
    final width = size;
    final height = size * 0.9;
    return Semantics(
      label: communityLikesLabel(likes),
      excludeSemantics: true,
      child: IgnorePointer(
        child: SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            painter: const _HeartPainter(),
            child: Align(
              // The heart's optical centre is in its round upper half, above
              // the middle of its box.
              alignment: const Alignment(0, -0.22),
              child: SizedBox(
                width: width * 0.54,
                height: height * 0.4,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    compactLikeCount(likes),
                    maxLines: 1,
                    textScaler: TextScaler.noScaling,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                      letterSpacing: -0.2,
                    ),
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

/// A solid ink body: a see-through one let the piece beneath read through.
const Color _kHeartInk = Color(0xE00C0C0E);

class _HeartPainter extends CustomPainter {
  const _HeartPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Two lobes meeting in a notch at the top, a point at the bottom.
    final path =
        Path()
          ..moveTo(w * 0.5, h * 0.98)
          ..cubicTo(w * 0.18, h * 0.74, 0, h * 0.52, 0, h * 0.3)
          ..cubicTo(0, h * 0.12, w * 0.14, 0, w * 0.29, 0)
          ..cubicTo(w * 0.39, 0, w * 0.46, h * 0.06, w * 0.5, h * 0.15)
          ..cubicTo(w * 0.54, h * 0.06, w * 0.61, 0, w * 0.71, 0)
          ..cubicTo(w * 0.86, 0, w, h * 0.12, w, h * 0.3)
          ..cubicTo(w, h * 0.52, w * 0.82, h * 0.74, w * 0.5, h * 0.98)
          ..close();
    canvas.drawPath(path, Paint()..color = _kHeartInk);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.28),
    );
  }

  @override
  bool shouldRepaint(covariant _HeartPainter oldDelegate) => false;
}
