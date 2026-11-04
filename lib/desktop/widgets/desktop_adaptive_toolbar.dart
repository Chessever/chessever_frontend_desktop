import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Keeps toolbar controls at their natural size, moving navigation below the
/// other actions when a single row cannot fit. Reports the single-row width
/// independently of the available space so a parent split can adapt to it.
class DesktopAdaptiveToolbar extends MultiChildRenderObjectWidget {
  DesktopAdaptiveToolbar({
    super.key,
    required Widget leading,
    Widget? navigation,
    Widget? trailing,
    this.onFullWidthChanged,
  }) : super(
         children: [
           leading,
           navigation ?? const SizedBox.shrink(),
           trailing ?? const SizedBox.shrink(),
         ],
       );

  final ValueChanged<double>? onFullWidthChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAdaptiveToolbar(onFullWidthChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBox renderObject,
  ) {
    (renderObject as _RenderAdaptiveToolbar).onFullWidthChanged =
        onFullWidthChanged;
  }
}

class _ToolbarParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderAdaptiveToolbar extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ToolbarParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ToolbarParentData> {
  _RenderAdaptiveToolbar(this.onFullWidthChanged);

  ValueChanged<double>? onFullWidthChanged;
  static const _gap = 8.0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ToolbarParentData) {
      child.parentData = _ToolbarParentData();
    }
  }

  /// Lays out the same children in both arrangements, preserving focus,
  /// tooltip and popover state when the window crosses the wrapping point.
  ({Size size, double fullWidth}) _layout(
    BoxConstraints constraints, {
    bool dry = false,
  }) {
    final children = getChildrenAsList();
    Size measure(RenderBox child, BoxConstraints limits) {
      if (dry) return child.getDryLayout(limits);
      child.layout(limits, parentUsesSize: true);
      return child.size;
    }

    final sizes = [
      for (final child in children) measure(child, const BoxConstraints()),
    ];
    final nonempty = sizes.where((s) => s.width > 0).length;
    final fullWidth =
        sizes.fold(0.0, (sum, s) => sum + s.width) +
        math.max(0, nonempty - 1) * _gap;
    final width =
        constraints.hasBoundedWidth ? constraints.maxWidth : fullWidth;
    for (var i = 0; i < children.length; i++) {
      if (sizes[i].width > width) {
        sizes[i] = measure(children[i], BoxConstraints(maxWidth: width));
      }
    }

    void place(int index, double x, double y) {
      if (dry) return;
      final data =
          children[index].parentData! as ContainerBoxParentData<RenderBox>;
      data.offset = Offset(x, y);
    }

    final leading = sizes[0];
    final navigation = sizes[1];
    final trailing = sizes[2];
    double height;
    if (width >= fullWidth) {
      height = sizes.fold(0.0, (h, s) => math.max(h, s.height));
      place(0, 0, (height - leading.height) / 2);
      final start = leading.width + (leading.width > 0 ? _gap : 0);
      final end = width - trailing.width - (trailing.width > 0 ? _gap : 0);
      place(
        1,
        (start + end - navigation.width) / 2,
        (height - navigation.height) / 2,
      );
      place(2, width - trailing.width, (height - trailing.height) / 2);
    } else {
      // Keep source/report actions and game actions together where possible.
      final topFits = leading.width + trailing.width + _gap <= width;
      height =
          topFits ? math.max(leading.height, trailing.height) : leading.height;
      place(0, 0, (height - leading.height) / 2);
      if (topFits) {
        place(2, width - trailing.width, (height - trailing.height) / 2);
      } else {
        place(2, width - trailing.width, height + _gap);
        height += _gap + trailing.height;
      }
      if (navigation.height > 0) {
        place(1, (width - navigation.width) / 2, height + _gap);
        height += _gap + navigation.height;
      } else {
        place(1, 0, 0);
      }
    }
    return (
      size: constraints.constrain(Size(width, height)),
      fullWidth: fullWidth,
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true).size;

  @override
  void performLayout() {
    final result = _layout(constraints);
    size = result.size;
    final report = onFullWidthChanged;
    if (report != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached && report == onFullWidthChanged) report(result.fullWidth);
      });
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
