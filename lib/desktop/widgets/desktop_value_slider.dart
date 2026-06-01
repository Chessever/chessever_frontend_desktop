import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Controlled numeric slider backed by forui's [FSlider].
///
/// forui 0.16 models slider values as a 0-1 selection, so callers pass their
/// real numeric range and this helper handles normalization.
class DesktopValueSlider extends StatefulWidget {
  const DesktopValueSlider({
    super.key,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
    this.divisions,
    this.tooltipFormatter,
  });

  final double min;
  final double max;
  final double value;
  final ValueChanged<double>? onChanged;
  final int? divisions;
  final String Function(double value)? tooltipFormatter;

  @override
  State<DesktopValueSlider> createState() => _DesktopValueSliderState();
}

class _DesktopValueSliderState extends State<DesktopValueSlider> {
  late FSliderController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  @override
  void didUpdateWidget(covariant DesktopValueSlider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (_needsNewController(oldWidget)) {
      final oldController = _controller;
      _controller = _buildController();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => oldController.dispose(),
      );
      return;
    }

    final current = _controller.selection;
    final targetOffset =
        _normalize(widget.value.clamp(widget.min, widget.max).toDouble());
    final span = widget.max - widget.min;
    // Drag echoes round to the nearest integer (via v.round() at the
    // call-site), so an offset diff up to ~1/span is just the controlled
    // value catching up to the drag. Anything beyond that is a real external
    // update (e.g. seedFromFen) that we should reflect on the thumb.
    final tolerance = span > 0 ? math.max(0.0005, 1.5 / span) : 0.0005;
    if ((current.offset.max - targetOffset).abs() <= tolerance) {
      return;
    }
    // The bare FSliderSelection factory builds a _Selection with zero
    // rawExtent, which would pin the thumb to offset 0. Use the live
    // selection's move() so we keep the attached ContinuousSelection /
    // DiscreteSelection with its real rawExtent intact.
    if (current.rawExtent.total > 0) {
      _controller.selection = current.move(
        min: false,
        to: targetOffset * current.rawExtent.total,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FSlider(
        controller: _controller,
        enabled: widget.onChanged != null,
        marks: _marks(),
        style: _sliderStyle,
        trackHitRegionCrossExtent: 32,
        onChange:
            widget.onChanged == null
                ? null
                : (selection) {
                  final raw = _denormalize(selection.offset.max);
                  widget.onChanged!(_snap(raw).clamp(widget.min, widget.max));
                },
        tooltipBuilder:
            (_, unitValue) => Text(
              widget.tooltipFormatter?.call(_snap(_denormalize(unitValue))) ??
                  _snap(_denormalize(unitValue)).round().toString(),
            ),
      ),
    );
  }

  double _normalize(double raw) {
    if (widget.max <= widget.min) return 0;
    return ((raw - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);
  }

  double _denormalize(double unit) =>
      widget.min + ((widget.max - widget.min) * unit.clamp(0, 1));

  double _snap(double raw) {
    final d = widget.divisions;
    if (d == null || d <= 0 || widget.max <= widget.min) return raw;
    final step = (widget.max - widget.min) / d;
    return widget.min + (((raw - widget.min) / step).round() * step);
  }

  FSliderController _buildController() {
    final selection = _selection();
    final divisions = widget.divisions;
    if (divisions != null && divisions > 0) {
      return FDiscreteSliderController(
        selection: selection,
        allowedInteraction: FSliderInteraction.tapAndSlideThumb,
      );
    }

    return FContinuousSliderController(
      selection: selection,
      allowedInteraction: FSliderInteraction.tapAndSlideThumb,
      stepPercentage: _stepPercentage,
    );
  }

  bool _needsNewController(DesktopValueSlider oldWidget) =>
      oldWidget.divisions != widget.divisions ||
      oldWidget.min != widget.min ||
      oldWidget.max != widget.max;

  FSliderSelection _selection() => FSliderSelection(
    max: _normalize(widget.value.clamp(widget.min, widget.max).toDouble()),
  );

  List<FSliderMark> _marks() {
    final divisions = widget.divisions;
    if (divisions == null || divisions <= 0) return const [];

    return List.generate(
      divisions + 1,
      (index) => FSliderMark(value: index / divisions, tick: false),
    );
  }

  double get _stepPercentage {
    final span = widget.max - widget.min;
    if (span <= 0) return 1;
    return (1 / span).clamp(0.001, 1.0);
  }

  FSliderStyle _sliderStyle(FSliderStyle style) {
    return style.copyWith(
      borderRadius: BorderRadius.circular(999),
      childPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      crossAxisExtent: 6,
      thumbSize: 18,
      thumbStyle: (thumb) => thumb.copyWith(borderWidth: 2),
    );
  }
}
