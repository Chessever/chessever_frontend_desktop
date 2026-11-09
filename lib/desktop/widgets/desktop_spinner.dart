import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Drop-in replacement for [CircularProgressIndicator] that stops animating
/// while it is not painted.
///
/// An indeterminate [CircularProgressIndicator] runs an [AnimationController]
/// for as long as it is mounted. Mounted is not the same as visible: a
/// load-more row built in a list's cache extent below the viewport, or a
/// spinner in a hidden pane, still schedules a frame at the display's refresh
/// rate. On renderers without a raster cache (the browser build and Impeller)
/// every one of those frames rasterizes the whole window again, so a spinner
/// nobody can see kept the Library at 120 full redraws a second.
///
/// This spinner advances from the frame clock inside `paint` and asks for the
/// next frame only after it was painted. A spinner outside the viewport, in an
/// offstage subtree or under a fully transparent [Opacity] is not painted, so
/// it schedules nothing; it continues when its parent paints it again.
///
/// A determinate spinner ([value] non-null) does not animate and is drawn by
/// [CircularProgressIndicator] itself.
class DesktopSpinner extends StatelessWidget {
  const DesktopSpinner({
    super.key,
    this.value,
    this.backgroundColor,
    this.color,
    this.valueColor,
    this.strokeWidth = 4.0,
    this.semanticsLabel,
  });

  final double? value;
  final Color? backgroundColor;
  final Color? color;
  final Animation<Color?>? valueColor;
  final double strokeWidth;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    if (value != null) {
      return CircularProgressIndicator(
        value: value,
        backgroundColor: backgroundColor,
        color: color,
        valueColor: valueColor,
        strokeWidth: strokeWidth,
        semanticsLabel: semanticsLabel,
      );
    }
    final indicatorTheme = ProgressIndicatorTheme.of(context);
    final resolvedColor =
        valueColor?.value ??
        color ??
        indicatorTheme.color ??
        Theme.of(context).colorScheme.primary;
    return Semantics(
      label: semanticsLabel,
      child: _PaintDrivenSpinner(
        color: resolvedColor,
        trackColor: backgroundColor ?? indicatorTheme.circularTrackColor,
        strokeWidth: strokeWidth,
      ),
    );
  }
}

class _PaintDrivenSpinner extends LeafRenderObjectWidget {
  const _PaintDrivenSpinner({
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final Color color;
  final Color? trackColor;
  final double strokeWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPaintDrivenSpinner(
        color: color,
        trackColor: trackColor,
        strokeWidth: strokeWidth,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderPaintDrivenSpinner renderObject,
  ) {
    renderObject
      ..color = color
      ..trackColor = trackColor
      ..strokeWidth = strokeWidth;
  }
}

/// Paints Material's indeterminate circular arc (the 2023 geometry) from the
/// frame clock. Visible for tests.
@visibleForTesting
class RenderPaintDrivenSpinner extends RenderBox {
  RenderPaintDrivenSpinner({
    required Color color,
    required Color? trackColor,
    required double strokeWidth,
  }) : _color = color,
       _trackColor = trackColor,
       _strokeWidth = strokeWidth;

  // Material's timing: one 1333 ms stroke cycle, one 2222 ms rotation, over a
  // period that holds a whole number of both.
  static const int _periodMs = 1333 * 2222;
  static const int _pathCount = _periodMs ~/ 1333;
  static const int _rotationCount = _periodMs ~/ 2222;
  static const Curve _head = Interval(0.0, 0.5, curve: Curves.fastOutSlowIn);
  static const Curve _tail = Interval(0.5, 1.0, curve: Curves.fastOutSlowIn);
  static const double _epsilon = .001;
  static const double _startAngle = -math.pi / 2.0;
  static const Size _defaultSize = Size.square(36);

  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  Color? get trackColor => _trackColor;
  Color? _trackColor;
  set trackColor(Color? value) {
    if (value == _trackColor) return;
    _trackColor = value;
    markNeedsPaint();
  }

  double get strokeWidth => _strokeWidth;
  double _strokeWidth;
  set strokeWidth(double value) {
    if (value == _strokeWidth) return;
    _strokeWidth = value;
    markNeedsPaint();
  }

  Duration? _start;
  Duration _lastFrameTime = Duration.zero;
  int? _frameCallbackId;

  /// Whether a frame is booked because this spinner was painted. False once
  /// it stops being painted. Visible for tests.
  @visibleForTesting
  bool get isAnimating => _frameCallbackId != null;

  // Only the spinner's own layer re-records each frame.
  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_defaultSize);

  @override
  double computeMinIntrinsicWidth(double height) => _defaultSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _defaultSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _defaultSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _defaultSize.height;

  @override
  void detach() {
    _cancelFrame();
    super.detach();
  }

  void _cancelFrame() {
    final id = _frameCallbackId;
    if (id == null) return;
    SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    _frameCallbackId = null;
  }

  void _onFrame(Duration _) {
    _frameCallbackId = null;
    // Stays dirty if this frame does not paint it (its layer is no longer
    // composited), so the next paint by its parent resumes the animation.
    if (attached) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final scheduler = SchedulerBinding.instance;
    // A paint outside a frame (an image capture) reuses the last pose.
    final inFrame = scheduler.schedulerPhase != SchedulerPhase.idle;
    final now = inFrame ? scheduler.currentFrameTimeStamp : _lastFrameTime;
    _lastFrameTime = now;
    final start = _start ??= now;
    final t = ((now - start).inMicroseconds / 1000 % _periodMs) / _periodMs;
    final stroke = (t * _pathCount) % 1.0;
    final head = _head.transform(stroke);
    final tail = _tail.transform(stroke);
    final rotation = (t * _rotationCount) % 1.0;

    final canvas = context.canvas;
    final arcRect = offset & size;
    if (_trackColor case final track?) {
      canvas.drawArc(
        arcRect,
        0,
        math.pi * 2 - _epsilon,
        false,
        Paint()
          ..color = track
          ..strokeWidth = _strokeWidth
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }
    final arcStart =
        _startAngle +
        tail * 3 / 2 * math.pi +
        rotation * math.pi * 2.0 +
        stroke * 0.5 * math.pi;
    final arcSweep = math.max(
      head * 3 / 2 * math.pi - tail * 3 / 2 * math.pi,
      _epsilon,
    );
    canvas.drawArc(
      arcRect,
      arcStart,
      arcSweep,
      false,
      Paint()
        ..color = _color
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.square
        ..style = PaintingStyle.stroke,
    );

    if (inFrame) _frameCallbackId ??= scheduler.scheduleFrameCallback(_onFrame);
  }
}
