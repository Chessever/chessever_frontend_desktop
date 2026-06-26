import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// A controlled integer range slider backed by forui's [FSlider].
///
/// forui 0.16 models a slider's value as a 0-1 selection that only gains its
/// real pixel extent once the [FSlider] attaches the controller during layout.
/// Re-assigning `controller.selection = FSliderSelection(...)` on every parent
/// rebuild throws that attached extent away (the bare factory builds a
/// selection whose `rawExtent` is zero and whose `move()` is a no-op), which is
/// what made the thumb jump to 0 and become unrecoverable mid-drag.
///
/// This widget keeps the attached selection alive: it rebuilds the controller
/// only when the numeric bounds change, and reconciles external start/end
/// updates through the live selection's `move()` after the frame so a drag is
/// never interrupted.
class DesktopRangeSlider extends StatefulWidget {
  const DesktopRangeSlider({
    super.key,
    required this.min,
    required this.max,
    required this.step,
    required this.start,
    required this.end,
    required this.onChanged,
  });

  final int min;
  final int max;
  final int step;
  final int start;
  final int end;
  final void Function(int start, int end) onChanged;

  @override
  State<DesktopRangeSlider> createState() => _DesktopRangeSliderState();
}

class _DesktopRangeSliderState extends State<DesktopRangeSlider> {
  late FContinuousSliderController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  @override
  void didUpdateWidget(covariant DesktopRangeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        oldWidget.step != widget.step) {
      final oldController = _controller;
      _controller = _buildController();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => oldController.dispose(),
      );
      return;
    }

    if (oldWidget.start != widget.start || oldWidget.end != widget.end) {
      _syncControllerSelection();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FSlider(
      controller: _controller,
      style: _rangeSliderStyle,
      trackHitRegionCrossExtent: 34,
      tooltipBuilder: (_, value) => Text(_denorm(value).toString()),
      semanticValueFormatterCallback: (value) => _denorm(value).toString(),
      onChange: _handleChange,
    );
  }

  FContinuousSliderController _buildController() {
    return FContinuousSliderController.range(
      selection: _selection(),
      stepPercentage: _stepPercentage,
    );
  }

  FSliderSelection _selection() {
    final start = _norm(widget.start);
    final end = _norm(widget.end).clamp(start, 1.0);
    return FSliderSelection(min: start, max: end);
  }

  void _syncControllerSelection() {
    final current = _controller.selection;
    final target = _selection();
    final tolerance = (_stepPercentage / 2) + 0.0005;
    if ((current.offset.min - target.offset.min).abs() <= tolerance &&
        (current.offset.max - target.offset.max).abs() <= tolerance) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final live = _controller.selection;
      final extent = live.rawExtent.total;
      if (extent <= 0) return;

      final targetStart = _norm(widget.start);
      final targetEnd = _norm(widget.end).clamp(targetStart, 1.0);
      final movedStart = live.move(min: true, to: targetStart * extent);
      final movedEnd = movedStart.move(min: false, to: targetEnd * extent);
      if (movedEnd != live) {
        _controller.selection = movedEnd;
      }
    });
  }

  double get _stepPercentage {
    final span = math.max(1, widget.max - widget.min);
    return (widget.step / span).clamp(0.001, 1.0);
  }

  double _norm(int value) {
    final span = math.max(1, widget.max - widget.min);
    return ((value - widget.min) / span).clamp(0.0, 1.0);
  }

  int _denorm(double value) {
    final span = math.max(1, widget.max - widget.min);
    final raw = widget.min + (span * value);
    final snapped = (raw / widget.step).round() * widget.step;
    return snapped.clamp(widget.min, widget.max);
  }

  void _handleChange(FSliderSelection selection) {
    final start = _denorm(selection.offset.min);
    final end = _denorm(selection.offset.max);
    final normalizedStart = start <= end ? start : end;
    final normalizedEnd = end >= start ? end : start;
    if (normalizedStart == widget.start && normalizedEnd == widget.end) return;
    widget.onChanged(normalizedStart, normalizedEnd);
  }
}

FSliderStyle _rangeSliderStyle(FSliderStyle style) {
  return style.copyWith(
    borderRadius: BorderRadius.circular(999),
    childPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
    crossAxisExtent: 6,
    thumbSize: 18,
    thumbStyle: (thumb) => thumb.copyWith(borderWidth: 2),
  );
}
