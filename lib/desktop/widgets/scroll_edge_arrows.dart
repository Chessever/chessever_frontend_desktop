import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

/// A scroll view with no scrollbar. Where there is more to see, the content
/// fades out at that edge and an arrow button sits over it; pressing the
/// arrow (or Enter on it) moves most of a view that way. The wheel and the
/// trackpad scroll as usual.
///
/// [child] is a [ScrollView] or [SingleChildScrollView] without its own
/// controller (it gets a wheel-aware one, like `DesktopScrollHost`), or use
/// [ScrollEdgeArrows.builder] to wire a controller yourself.
///
/// By default it fills its box. With [shrinkWrap] it is as long as its
/// scroll view along the scroll axis (a [SingleChildScrollView] under loose
/// constraints is as long as its content, up to the limit), sized in the
/// same layout pass, while still filling the cross axis.
class ScrollEdgeArrows extends StatefulWidget {
  const ScrollEdgeArrows({
    required Widget this.child,
    this.axis,
    this.fade = 28,
    this.inset = 6,
    this.shrinkWrap = false,
    super.key,
  }) : builder = null;

  const ScrollEdgeArrows.builder({
    required Widget Function(BuildContext context, ScrollController controller)
    this.builder,
    required Axis this.axis,
    this.fade = 28,
    this.inset = 6,
    this.shrinkWrap = false,
    super.key,
  }) : child = null;

  final Widget? child;
  final Widget Function(BuildContext context, ScrollController controller)?
  builder;

  /// The scroll direction; read from [child] when null.
  final Axis? axis;

  /// How far the content fades out under an arrow, in pixels.
  final double fade;

  /// Gap between an arrow and the edge.
  final double inset;

  /// Size to the scroll view along the scroll axis instead of filling.
  final bool shrinkWrap;

  @override
  State<ScrollEdgeArrows> createState() => _ScrollEdgeArrowsState();
}

class _ScrollEdgeArrowsState extends State<ScrollEdgeArrows> {
  final DesktopScrollController _controller = DesktopScrollController();

  /// Keeps the scroll subtree's state when the fade mask is added or
  /// removed around it: without it the subtree would remount (scroll
  /// position, focus, text fields and running animations lost) every time
  /// the content starts or stops overflowing.
  final GlobalKey _viewKey = GlobalKey(debugLabel: 'ScrollEdgeArrows.view');
  bool _before = false;
  bool _after = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Axis get _axis {
    final axis = widget.axis;
    if (axis != null) return axis;
    final child = widget.child;
    if (child is ScrollView) return child.scrollDirection;
    if (child is SingleChildScrollView) return child.scrollDirection;
    return Axis.vertical;
  }

  bool _onMetrics(ScrollMetrics metrics, {bool now = false}) {
    if (metrics.axis != _axis) return false;
    // Half a pixel of slack: fractional extents never leave a lone arrow.
    final before = metrics.pixels > metrics.minScrollExtent + 0.5;
    final after = metrics.pixels < metrics.maxScrollExtent - 0.5;
    if (before != _before || after != _after) {
      if (now) {
        setState(() {
          _before = before;
          _after = after;
        });
        return false;
      }
      // Metrics arrive during layout; update after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _before = before;
          _after = after;
        });
      });
    }
    return false;
  }

  void _step(int direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (position.pixels +
            direction * position.viewportDimension * 0.8)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// The first layout sends no metrics notification: read the position
  /// once the frame is laid out (it only rebuilds when an arrow changes).
  void _checkAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      if (position.hasContentDimensions) _onMetrics(position, now: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    _checkAfterLayout();
    final axis = _axis;
    final horizontal = axis == Axis.horizontal;
    final builder = widget.builder;
    Widget view =
        builder != null
            ? builder(context, _controller)
            : PrimaryScrollController(
              controller: _controller,
              scrollDirection: axis,
              automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
              child: widget.child!,
            );
    view = ScrollConfiguration(
      key: _viewKey,
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => n.depth == 0 && _onMetrics(n.metrics),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) => n.depth == 0 && _onMetrics(n.metrics),
          child: view,
        ),
      ),
    );

    // The content fades out under an arrow, so the edge itself says there
    // is more; the fade lifts when that end is reached.
    final fade = widget.fade;
    if (_before || _after) {
      view = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final extent = horizontal ? rect.width : rect.height;
          final stop = extent <= 0 ? 0.0 : (fade / extent).clamp(0.0, 0.5);
          return LinearGradient(
            begin: horizontal ? Alignment.centerLeft : Alignment.topCenter,
            end: horizontal ? Alignment.centerRight : Alignment.bottomCenter,
            colors: [
              _before ? Colors.transparent : Colors.black,
              Colors.black,
              Colors.black,
              _after ? Colors.transparent : Colors.black,
            ],
            stops: [0, stop, 1 - stop, 1],
          ).createShader(rect);
        },
        child: view,
      );
    }

    final inset = widget.inset;
    return Stack(
      fit: widget.shrinkWrap ? StackFit.passthrough : StackFit.expand,
      children: [
        // The scroll view is the Stack's only non-positioned child, so the
        // Stack takes its size; the arrows sit over it.
        widget.shrinkWrap ? _FillCrossAxis(axis: axis, child: view) : view,
        if (_before)
          horizontal
              ? Positioned(
                left: inset,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _EdgeArrow(
                    icon: Icons.chevron_left_rounded,
                    label: 'Scroll left',
                    onPress: () => _step(-1),
                  ),
                ),
              )
              : Positioned(
                top: inset,
                left: 0,
                right: 0,
                child: Center(
                  child: _EdgeArrow(
                    icon: Icons.keyboard_arrow_up_rounded,
                    label: 'Scroll up',
                    onPress: () => _step(-1),
                  ),
                ),
              ),
        if (_after)
          horizontal
              ? Positioned(
                right: inset,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _EdgeArrow(
                    icon: Icons.chevron_right_rounded,
                    label: 'More to the right',
                    onPress: () => _step(1),
                  ),
                ),
              )
              : Positioned(
                bottom: inset,
                left: 0,
                right: 0,
                child: Center(
                  child: _EdgeArrow(
                    icon: Icons.keyboard_arrow_down_rounded,
                    label: 'More below',
                    onPress: () => _step(1),
                  ),
                ),
              ),
      ],
    );
  }
}

/// Fills the bounded cross axis and passes the scroll axis through, so a
/// shrink-wrapped scroller stays as wide (or tall) as its slot.
class _FillCrossAxis extends SingleChildRenderObjectWidget {
  const _FillCrossAxis({required this.axis, required super.child});

  final Axis axis;

  @override
  _RenderFillCrossAxis createRenderObject(BuildContext context) =>
      _RenderFillCrossAxis(axis);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFillCrossAxis renderObject,
  ) {
    renderObject.axis = axis;
  }
}

class _RenderFillCrossAxis extends RenderProxyBox {
  _RenderFillCrossAxis(this._axis);

  Axis _axis;
  set axis(Axis value) {
    if (value == _axis) return;
    _axis = value;
    markNeedsLayout();
  }

  BoxConstraints _fill(BoxConstraints c) => switch (_axis) {
    Axis.vertical when c.hasBoundedWidth => c.copyWith(minWidth: c.maxWidth),
    Axis.horizontal when c.hasBoundedHeight => c.copyWith(
      minHeight: c.maxHeight,
    ),
    _ => c,
  };

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      child?.getDryLayout(_fill(constraints)) ?? constraints.smallest;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_fill(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}

/// A small rounded button over the content's edge: the shell's button
/// vocabulary (8 radius, divider border, white70 to white on hover), with
/// an opaque fill so the content under it never shows through.
class _EdgeArrow extends StatelessWidget {
  const _EdgeArrow({
    required this.icon,
    required this.label,
    required this.onPress,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: label,
        child: ClickCursor(
          child: FTappable(
            semanticsLabel: label,
            style:
                (style) => style.copyWith(motion: (_) => FTappableMotion.none),
            onPress: onPress,
            builder: (context, states, _) {
              final hovered = states.contains(WidgetState.hovered);
              final pressed = states.contains(WidgetState.pressed);
              final focused = states.contains(WidgetState.focused);
              return AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: pressed || hovered ? kBlack3Color : kBlack2Color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        focused
                            ? kPrimaryColor.withValues(alpha: 0.55)
                            : hovered
                            ? kWhiteColor.withValues(alpha: 0.14)
                            : kDividerColor,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  icon,
                  size: 18,
                  color: hovered || focused ? kWhiteColor : kWhiteColor70,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
