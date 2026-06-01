import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:motor/motor.dart';

import 'package:chessever/theme/app_theme.dart';

/// Desktop-tuned evaluation bar.
///
/// Replaces the mobile `EvaluationBarWidget` on the desktop board pane.
/// Mobile's bar uses `responsive_helper.dart` extensions (`.f`, `.h`)
/// that scale based on tablet vs phone — a 1440×900 desktop window gets
/// classed as a tablet and the bar's text shrinks to ~5 px, which read
/// as "tablet view fallback". This widget uses fixed pixel sizes so the
/// desktop board has a deliberate desktop typography, independent of
/// the mobile responsive system.
///
/// Visual contract:
///  - White takes the bottom (or top, when flipped); colours match
///    `EvaluationBarWidget` so the rest of the desktop UI stays
///    consistent with mobile cards.
///  - The numeric readout sits at the meeting line, in `kPrimaryColor`,
///    on a tabular-figure face.
///  - The fill animates with `motor`'s `CupertinoMotion.smooth` between
///    eval updates — same physics the mobile bar uses, just driven from
///    here so we don't pull mobile's responsive helper.
class DesktopEvalBar extends StatefulWidget {
  const DesktopEvalBar({
    super.key,
    required this.width,
    required this.height,
    required this.isFlipped,
    required this.evaluation,
    required this.mate,
    required this.isEvaluating,
    this.positionKey,
  });

  final double width;
  final double height;
  final bool isFlipped;
  final double? evaluation;
  final int? mate;
  final bool isEvaluating;

  /// Used to detect "the user moved to a new position" so we can show a
  /// `…` placeholder while the next eval lands instead of pinning a
  /// stale number.
  final String? positionKey;

  @override
  State<DesktopEvalBar> createState() => _DesktopEvalBarState();
}

class _DesktopEvalBarState extends State<DesktopEvalBar> {
  double? _lastEval;
  int? _lastMate;
  bool _awaiting = false;
  String? _lastPositionKey;
  double _whiteRatioTarget = 0.5;

  @override
  void initState() {
    super.initState();
    _lastEval = widget.evaluation;
    _lastMate = widget.mate;
    _lastPositionKey = widget.positionKey;
    _awaiting = widget.evaluation == null && widget.mate == null;
    _whiteRatioTarget = _ratioForEval(_lastEval ?? 0.0, _lastMate ?? 0);
  }

  @override
  void didUpdateWidget(covariant DesktopEvalBar old) {
    super.didUpdateWidget(old);
    final positionChanged = widget.positionKey != _lastPositionKey;
    final hasIncoming = widget.evaluation != null || widget.mate != null;
    final mateChanged = widget.mate != _lastMate;
    final evalChanged =
        widget.evaluation != null &&
        (widget.evaluation != _lastEval || positionChanged);
    var changed = false;

    if (_awaiting && !widget.isEvaluating && !hasIncoming) {
      _awaiting = false;
      _lastEval = null;
      _lastMate = null;
      _whiteRatioTarget = 0.5;
      changed = true;
    }
    if (positionChanged) {
      _lastPositionKey = widget.positionKey;
      _awaiting = true;
      changed = true;
    }
    if (mateChanged) _lastMate = widget.mate;
    if (evalChanged) {
      _lastEval = widget.evaluation;
    }
    if (positionChanged && widget.evaluation != null && !evalChanged) {
      _lastEval = widget.evaluation;
    }

    final shouldUpdateRatio =
        mateChanged ||
        evalChanged ||
        (positionChanged && hasIncoming) ||
        (_awaiting && hasIncoming);
    if (shouldUpdateRatio) {
      _awaiting = false;
      _whiteRatioTarget =
          _whiteRatio(
            _effectiveEval(_lastEval, _lastMate),
          ).clamp(0.0, 1.0).toDouble();
      changed = true;
    }
    if (changed) setState(() {});
  }

  double _effectiveEval(double? e, int? mate) {
    final m = mate ?? _lastMate;
    if (m != null && m != 0) return m > 0 ? 10.0 : -10.0;
    return e ?? 0.0;
  }

  double _whiteRatio(double e) => _normalizedEvalToRatio(e);

  String _displayText() {
    final rawEval = widget.evaluation ?? _lastEval ?? 0.0;
    final rawMate = widget.mate ?? _lastMate;
    final hasEval =
        !_awaiting &&
        ((widget.evaluation != null || _lastEval != null) || rawMate != null);
    final showLoading = _awaiting || (widget.isEvaluating && !hasEval);
    if (showLoading) return '…';
    if (!hasEval) return '';
    if (rawEval.abs() >= 10.0 && rawMate != null) return '#$rawMate';
    return _formatSignedEval(rawEval);
  }

  @override
  Widget build(BuildContext context) {
    return SingleMotionBuilder(
      value: _whiteRatioTarget,
      motion: const CupertinoMotion.smooth(),
      builder: (context, animatedRatio, _) {
        final whiteRatio = animatedRatio.clamp(0.0, 1.0).toDouble();
        final blackRatio = 1.0 - whiteRatio;
        final whiteHeight = whiteRatio * widget.height;
        final blackHeight = blackRatio * widget.height;
        final topHeight = widget.isFlipped ? whiteHeight : blackHeight;
        final bottomHeight = widget.isFlipped ? blackHeight : whiteHeight;
        final topColor = widget.isFlipped ? kWhiteColor : kPopUpColor;
        final bottomColor = widget.isFlipped ? kPopUpColor : kWhiteColor;

        // Fixed-px badge — 18 px tall, large enough to read on a desktop
        // screen but small enough to not dominate a 22 px-wide bar.
        const badgeHeight = 18.0;
        final badgeTop = (topHeight - badgeHeight / 2).clamp(
          0.0,
          widget.height - badgeHeight,
        );

        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  width: widget.width,
                  height: topHeight,
                  color: topColor,
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: widget.width,
                  height: bottomHeight,
                  color: bottomColor,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: badgeTop,
                child: Container(
                  width: widget.width,
                  height: badgeHeight,
                  alignment: Alignment.center,
                  color: kPrimaryColor,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        _displayText(),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: kBackgroundColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          fontFeatures: [FontFeature.tabularFigures()],
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _formatSignedEval(double evaluation) {
  final value = evaluation.abs() < 0.05 ? 0.0 : evaluation;
  if (value == 0.0) return '0.0';
  final formatted = value.toStringAsFixed(1);
  return value > 0 ? '+$formatted' : formatted;
}

double _normalizedEvalToRatio(double eval) {
  const double scale = 3.0;
  const double minRatio = 0.02;
  const double maxRatio = 0.98;
  final clamped = eval.clamp(-20.0, 20.0);
  final logistic = 1.0 / (1.0 + math.exp(-clamped / scale));
  return logistic.clamp(minRatio, maxRatio);
}

double _ratioForEval(double evaluation, int mate) {
  final effective = mate != 0 ? (mate > 0 ? 10.0 : -10.0) : evaluation;
  return _normalizedEvalToRatio(effective);
}
