import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import '../../theme/app_theme.dart';

const Duration _kSplitAnimationDuration = Duration(milliseconds: 220);
const Curve _kSplitAnimationCurve = Curves.easeOutCubic;

/// Describes one section of a [ResizableSplitView].
class SplitChild {
  const SplitChild({
    required this.child,
    this.minSize = 120,
    this.maxSize,
    this.initialWeight = 1.0,
    this.label,
    this.collapsedIcon,
    this.dismissible = true,
    this.initialCollapsed = false,
    this.onRestore,
  });

  final Widget child;

  /// Minimum size along the split axis, in logical pixels.
  final double minSize;

  /// Optional maximum size along the split axis.
  final double? maxSize;

  /// Relative weight used when initialising the split. The widget normalises
  /// the list of weights so they sum to 1 across all children.
  final double initialWeight;

  /// Human-readable label. When [dismissible] is true and the panel has been
  /// collapsed, this label becomes the restore button's tooltip.
  final String? label;

  /// Icon shown on the restore button after this child is collapsed.
  final IconData? collapsedIcon;

  /// Whether this section can be collapsed via the gutter chevron. The very
  /// first and last sections are always restorable through the collapsed
  /// rail's expand button, regardless of position.
  final bool dismissible;

  /// Whether this section should start collapsed on first mount. Only
  /// honoured when [dismissible] is true. Persisted layout (via the parent
  /// view's `storageKey`) overrides this default after `_restore()` lands.
  final bool initialCollapsed;

  /// Optional hook invoked when a collapsed rail expands this child again.
  final VoidCallback? onRestore;
}

/// A flexible split layout with draggable gutters between adjacent children.
///
/// - Hover the gutter → cursor swaps to the platform resize affordance.
/// - Drag the gutter → redistributes weight between the two adjacent panels
///   while honouring each child's `minSize` / `maxSize`.
/// - Hover the gutter → two chevron buttons appear, each collapsing the
///   neighbour they point at. A collapsed neighbour becomes a compact icon
///   restore button using the panel's [SplitChild.label] as its tooltip.
///
/// Persistence: when [storageKey] is non-null, the widget writes the weights
/// and the set of collapsed indices to [SharedPreferences] so panes feel
/// sticky across sessions.
class ResizableSplitView extends StatefulWidget {
  const ResizableSplitView({
    super.key,
    required this.axis,
    required this.children,
    this.gutterThickness = 8,
    this.gutterColor = kDividerColor,
    this.collapsedRailThickness = 48,
    this.storageKey,
    this.controller,
  }) : assert(children.length >= 2, 'Need at least two split children');

  final Axis axis;
  final List<SplitChild> children;
  final double gutterThickness;
  final Color gutterColor;
  final double collapsedRailThickness;

  /// Stable key for persistence. When null, layout resets every time the
  /// widget is rebuilt from scratch.
  final String? storageKey;

  /// Optional external controller for programmatic collapse / restore. Lets
  /// child widgets trigger their own dismissal (e.g. an "X" button inside a
  /// rail) without needing to surface state up.
  final ResizableSplitViewController? controller;

  @override
  State<ResizableSplitView> createState() => _ResizableSplitViewState();
}

/// External handle for programmatic [ResizableSplitView] collapse / restore.
///
/// Attach to a view via `ResizableSplitView(controller: ...)`. Calls are
/// no-ops until the view is mounted and after the view is disposed, so the
/// controller is safe to own across rebuilds.
class ResizableSplitViewController {
  _ResizableSplitViewState? _state;

  void _attach(_ResizableSplitViewState state) => _state = state;
  void _detach(_ResizableSplitViewState state) {
    if (identical(_state, state)) _state = null;
  }

  /// Collapse [index] into its rail. No-op when [index] is invalid, when
  /// the child is not dismissible, or before the view has mounted.
  void collapse(int index, {bool persist = true}) =>
      _state?._collapseExternal(index, persist: persist);

  /// Expand [index] back to its weighted size.
  void restore(int index) => _state?._restoreIndex(index);

  /// Resize [index] to [sizePx] along the split axis, redistributing the
  /// delta into neighbouring visible panes while respecting min/max bounds.
  double? setSize(int index, double sizePx, {bool persist = true}) =>
      _state?._setSizeExternal(index, sizePx, persist: persist);

  /// Resize [index] to [fraction] of the currently available visible split
  /// area, after gutters and collapsed rails are reserved.
  void setFraction(int index, double fraction, {bool persist = true}) =>
      _state?._setFractionExternal(index, fraction, persist: persist);

  bool isCollapsed(int index) => _state?._collapsed.contains(index) ?? false;
}

class _ResizableSplitViewState extends State<ResizableSplitView> {
  late List<double> _weights;
  late Set<int> _collapsed;
  Timer? _saveDebounce;
  bool _animateLayout = false;
  int _animationTicket = 0;

  @override
  void initState() {
    super.initState();
    _weights = _normalize(
      widget.children.map((c) => c.initialWeight).toList(growable: false),
    );
    _collapsed = <int>{
      for (var i = 0; i < widget.children.length; i++)
        if (widget.children[i].dismissible &&
            widget.children[i].initialCollapsed)
          i,
    };
    widget.controller?._attach(this);
    if (widget.storageKey != null) {
      _restore();
    }
  }

  @override
  void didUpdateWidget(covariant ResizableSplitView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.children.length != widget.children.length) {
      _weights = _normalize(
        widget.children.map((c) => c.initialWeight).toList(growable: false),
      );
      // Adding or removing a child re-numbers every subsequent slot, so an
      // index like `{0}` that previously meant "Games rail collapsed" can
      // suddenly mean "Board collapsed". That misfires on non-dismissible
      // children (Board) and hides the wrong pane. Wipe the set; the
      // controller / storage layer will re-collapse intentionally if
      // needed.
      _collapsed = <int>{};
    }
    if (oldWidget.storageKey != widget.storageKey &&
        widget.storageKey != null) {
      // Storage key swap (e.g. focus-mode toggle) means a different saved
      // layout is now authoritative. Re-load so the new key's weights and
      // collapse state apply. _restore silently ignores length mismatches,
      // so the reset above still wins when the new key holds stale data.
      _restore();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _saveDebounce?.cancel();
    super.dispose();
  }

  void _collapseExternal(int index, {bool persist = true}) {
    if (index < 0 || index >= widget.children.length) return;
    _collapse(index, persist: persist);
  }

  double? _setSizeExternal(int index, double sizePx, {bool persist = true}) {
    if (index < 0 || index >= widget.children.length) return null;
    if (_collapsed.contains(index)) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final totalAxis =
        _isHorizontal() ? renderObject.size.width : renderObject.size.height;
    if (!totalAxis.isFinite || totalAxis <= 0) return null;

    final visible = <int>[];
    for (var i = 0; i < widget.children.length; i++) {
      if (!_collapsed.contains(i)) visible.add(i);
    }
    if (!visible.contains(index)) return null;

    final separatorTotal =
        widget.gutterThickness * (widget.children.length - 1);
    final reservedForRails =
        widget.collapsedRailThickness *
        (widget.children.length - visible.length);
    final available = totalAxis - separatorTotal - reservedForRails;
    if (available <= 0) return null;

    final sizes = _resolveVisibleSizes(visible, available);
    if (_resizeVisiblePane(sizes, visible, index, sizePx)) {
      _setWeightsFromVisibleSizes(sizes, visible);
      if (persist) _scheduleSave();
    }
    return sizes[index];
  }

  void _setFractionExternal(int index, double fraction, {bool persist = true}) {
    if (index < 0 || index >= widget.children.length) return;
    if (_collapsed.contains(index)) return;

    final visible = <int>[];
    for (var i = 0; i < widget.children.length; i++) {
      if (!_collapsed.contains(i)) visible.add(i);
    }
    if (!visible.contains(index)) return;
    final others = visible.where((i) => i != index).toList(growable: false);
    if (others.isEmpty) return;

    final clamped = fraction.clamp(0.0, 1.0).toDouble();
    final visibleWeightSum = visible.fold<double>(0, (a, i) => a + _weights[i]);
    final baseWeight = visibleWeightSum > 0 ? visibleWeightSum : 1.0;
    final nextIndexWeight = baseWeight * clamped;
    final nextOtherWeight = baseWeight - nextIndexWeight;
    final otherWeightSum = others.fold<double>(0, (a, i) => a + _weights[i]);
    final newWeights = List<double>.from(_weights);
    newWeights[index] = nextIndexWeight;
    for (final other in others) {
      newWeights[other] =
          otherWeightSum > 0
              ? _weights[other] / otherWeightSum * nextOtherWeight
              : nextOtherWeight / others.length;
    }

    _animationTicket++;
    setState(() {
      _animateLayout = false;
      _weights = newWeights;
    });
    if (persist) _scheduleSave();
  }

  Future<void> _restore() async {
    final key = widget.storageKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('split_view::$key');
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final w = (decoded['weights'] as List?)?.cast<num>();
      final collapsed = (decoded['collapsed'] as List?)?.cast<num>();
      List<double>? restoredWeights;
      Set<int> restoredCollapsed = <int>{};
      if (w != null && w.length == widget.children.length) {
        restoredWeights = _normalize(
          w.map((e) => e.toDouble()).toList(growable: false),
        );
      }
      if (collapsed != null) {
        restoredCollapsed =
            collapsed
                .map((e) => e.toInt())
                .where((i) => i >= 0 && i < widget.children.length)
                .where((i) => widget.children[i].dismissible)
                .toSet();
      }
      if (!mounted) return;
      setState(() {
        if (restoredWeights != null) _weights = restoredWeights;
        _collapsed = restoredCollapsed;
      });
    } catch (_) {
      // Bad stored value — fall back to initial layout silently.
    }
  }

  void _scheduleSave() {
    final key = widget.storageKey;
    if (key == null) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'split_view::$key',
          jsonEncode({
            'weights': _weights,
            'collapsed': _collapsed.toList()..sort(),
          }),
        );
      } catch (_) {}
    });
  }

  List<double> _normalize(List<double> raw) {
    final total = raw.fold<double>(0, (a, b) => a + (b <= 0 ? 0 : b));
    if (total <= 0) {
      final v = 1.0 / raw.length;
      return List<double>.filled(raw.length, v);
    }
    return raw.map((e) => (e <= 0 ? 0 : e) / total).toList(growable: false);
  }

  bool _isHorizontal() => widget.axis == Axis.horizontal;

  void _runLayoutAnimation(VoidCallback mutate) {
    final ticket = ++_animationTicket;
    setState(() {
      _animateLayout = true;
      mutate();
    });
    Future<void>.delayed(_kSplitAnimationDuration, () {
      if (!mounted || ticket != _animationTicket) return;
      setState(() => _animateLayout = false);
    });
  }

  void _collapse(int index, {bool persist = true}) {
    if (!widget.children[index].dismissible) return;
    if (_collapsed.contains(index)) return;
    _runLayoutAnimation(() => _collapsed = {..._collapsed, index});
    if (persist) _scheduleSave();
  }

  void _restoreIndex(int index) {
    if (!_collapsed.contains(index)) return;
    widget.children[index].onRestore?.call();
    _runLayoutAnimation(
      () => _collapsed = _collapsed.where((i) => i != index).toSet(),
    );
    _scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final n = widget.children.length;
        final isHorizontal = _isHorizontal();
        final totalAxis =
            isHorizontal ? constraints.maxWidth : constraints.maxHeight;

        // Decide which separators sit between the slots. We always render a
        // separator between two slots; a gutter goes between two visible
        // slots, a thin spacer between a visible and a collapsed slot. The
        // collapsed slot itself carries its own restore chevron.
        final visible = <int>[];
        for (var i = 0; i < n; i++) {
          if (!_collapsed.contains(i)) visible.add(i);
        }

        // Distribute totalAxis across collapsed rails first, then split the
        // remainder between visible panels using their stored weights.
        final railThickness = widget.collapsedRailThickness;
        final railCount = n - visible.length;
        final separatorCount = (n - 1);
        final separatorTotal = widget.gutterThickness * separatorCount;
        final reservedForRails = railThickness * railCount;
        final availableForVisible =
            totalAxis - separatorTotal - reservedForRails;

        if (!totalAxis.isFinite || totalAxis <= 0) {
          return const SizedBox.shrink();
        }

        final visibleSizes =
            visible.isEmpty
                ? const <int, double>{}
                : _resolveVisibleSizes(visible, availableForVisible);

        final slots = <Widget>[];
        for (var i = 0; i < n; i++) {
          if (_collapsed.contains(i)) {
            slots.add(
              _CollapsedRail(
                axis: widget.axis,
                thickness: railThickness,
                label: widget.children[i].label,
                icon:
                    widget.children[i].collapsedIcon ??
                    _fallbackCollapsedIcon(widget.children[i].label),
                animate: _animateLayout,
                onExpand: () => _restoreIndex(i),
              ),
            );
          } else {
            slots.add(_axisBox(visibleSizes[i] ?? 0, widget.children[i].child));
          }
          if (i != n - 1) {
            // Choose what to render between slot i and slot i+1.
            final leftCollapsed = _collapsed.contains(i);
            final rightCollapsed = _collapsed.contains(i + 1);
            if (leftCollapsed && rightCollapsed) {
              slots.add(
                _StaticDivider(
                  axis: widget.axis,
                  thickness: widget.gutterThickness,
                  color: widget.gutterColor,
                ),
              );
            } else if (leftCollapsed || rightCollapsed) {
              slots.add(
                _StaticDivider(
                  axis: widget.axis,
                  thickness: widget.gutterThickness,
                  color: widget.gutterColor,
                ),
              );
            } else {
              slots.add(
                _Gutter(
                  axis: widget.axis,
                  thickness: widget.gutterThickness,
                  color: widget.gutterColor,
                  leftDismissible: widget.children[i].dismissible,
                  rightDismissible: widget.children[i + 1].dismissible,
                  leftLabel: widget.children[i].label,
                  rightLabel: widget.children[i + 1].label,
                  onDrag:
                      (delta) =>
                          _handleDrag(visible, i, delta, availableForVisible),
                  onDragEnd: _scheduleSave,
                  onCollapseLeft: () => _collapse(i),
                  onCollapseRight: () => _collapse(i + 1),
                ),
              );
            }
          }
        }

        return isHorizontal
            ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: slots,
            )
            : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: slots,
            );
      },
    );
  }

  Widget _axisBox(double size, Widget child) {
    return _AnimatedAxisBox(
      axis: widget.axis,
      size: size,
      animate: _animateLayout,
      child: child,
    );
  }

  /// Resolves on-screen sizes for the still-visible panels, honouring per-
  /// child min/max.
  ///
  /// Returns a map from the original child index to the resolved size.
  Map<int, double> _resolveVisibleSizes(List<int> visible, double available) {
    if (available <= 0 || visible.isEmpty) {
      return {for (final i in visible) i: 0};
    }
    // Oversubscribed track — sum of declared minSize already exceeds the
    // available space, so no allocation can satisfy every panel. Scale each
    // minSize down proportionally so the parent Row/Column never overflows.
    // Happens at the OS-enforced min window size when sibling minSizes were
    // calibrated for a slightly larger track; clipping inside an undersized
    // panel is far less broken than a layout overflow strip.
    final minTotal = visible.fold<double>(
      0,
      (a, i) => a + widget.children[i].minSize,
    );
    if (minTotal > available) {
      final scale = available / minTotal;
      return {for (final i in visible) i: widget.children[i].minSize * scale};
    }
    if (visible.length == 1) {
      // A collapsed sibling should surrender its space completely. Honouring a
      // lone pane's maxSize here leaves unused dead area in the split track
      // (for example, closing the Library preview kept the database grid stuck
      // at its capped height instead of letting it fill the window).
      return {visible.single: available};
    }

    final sizes = <int, double>{for (final i in visible) i: 0};
    final locked = <int, bool>{for (final i in visible) i: false};

    var remaining = available;
    var remainingWeight = visible.fold<double>(0, (a, i) => a + _weights[i]);

    var didLock = true;
    while (didLock) {
      didLock = false;
      for (final i in visible) {
        if (locked[i] == true) continue;
        final share =
            remainingWeight <= 0
                ? 0.0
                : _weights[i] / remainingWeight * remaining;
        final c = widget.children[i];
        final clampedMin = share < c.minSize;
        final clampedMax = c.maxSize != null && share > c.maxSize!;
        if (clampedMin || clampedMax) {
          sizes[i] = clampedMin ? c.minSize : c.maxSize!;
          locked[i] = true;
          remaining -= sizes[i]!;
          remainingWeight -= _weights[i];
          didLock = true;
        }
      }
    }
    for (final i in visible) {
      if (locked[i] == true) continue;
      sizes[i] =
          remainingWeight <= 0
              ? 0.0
              : _weights[i] / remainingWeight * remaining;
    }
    return sizes;
  }

  void _handleDrag(
    List<int> visible,
    int gutterIndex,
    double deltaPx,
    double available,
  ) {
    if (available <= 0) return;
    // gutterIndex is the index of the slot to the left of the gutter, but we
    // only drag between two visible neighbours, so look up the next visible
    // index after gutterIndex.
    if (!visible.contains(gutterIndex)) return;
    final pos = visible.indexOf(gutterIndex);
    if (pos < 0 || pos + 1 >= visible.length) return;
    final leftIdx = gutterIndex;
    final rightIdx = visible[pos + 1];

    final sizes = _resolveVisibleSizes(visible, available);

    final leftMin = widget.children[leftIdx].minSize;
    final leftMax = widget.children[leftIdx].maxSize ?? double.infinity;
    final rightMin = widget.children[rightIdx].minSize;
    final rightMax = widget.children[rightIdx].maxSize ?? double.infinity;

    final oldLeft = sizes[leftIdx] ?? 0;
    final oldRight = sizes[rightIdx] ?? 0;

    final newLeft = (oldLeft + deltaPx).clamp(leftMin, leftMax).toDouble();
    final actualDelta = newLeft - oldLeft;
    final newRight =
        (oldRight - actualDelta).clamp(rightMin, rightMax).toDouble();
    final settledDelta = oldRight - newRight;
    final finalLeft = oldLeft + settledDelta;

    sizes[leftIdx] = finalLeft;
    sizes[rightIdx] = newRight;

    // Push the new visible sizes back into the global weight vector while
    // leaving collapsed slots' stored weights untouched (they'll be honoured
    // when restored).
    final visibleTotal = visible.fold<double>(0, (a, i) => a + (sizes[i] ?? 0));
    if (visibleTotal <= 0) return;
    _setWeightsFromVisibleSizes(sizes, visible);
  }

  void _setWeightsFromVisibleSizes(Map<int, double> sizes, List<int> visible) {
    final visibleTotal = visible.fold<double>(0, (a, i) => a + (sizes[i] ?? 0));
    if (visibleTotal <= 0) return;
    final visibleWeightSum = visible.fold<double>(0, (a, i) => a + _weights[i]);
    final newWeights = List<double>.from(_weights);
    for (final i in visible) {
      newWeights[i] = (sizes[i] ?? 0) / visibleTotal * visibleWeightSum;
    }
    _animationTicket++;
    setState(() {
      _animateLayout = false;
      _weights = newWeights;
    });
  }

  bool _resizeVisiblePane(
    Map<int, double> sizes,
    List<int> visible,
    int index,
    double targetSize,
  ) {
    final child = widget.children[index];
    final current = sizes[index] ?? 0;
    final otherMinTotal = visible
        .where((i) => i != index)
        .fold<double>(0, (a, i) => a + widget.children[i].minSize);
    final totalVisible = visible.fold<double>(0, (a, i) => a + (sizes[i] ?? 0));
    final maxBySiblings = math.max(child.minSize, totalVisible - otherMinTotal);
    final childMax = child.maxSize ?? double.infinity;
    final target =
        targetSize
            .clamp(child.minSize, math.min(childMax, maxBySiblings))
            .toDouble();
    final delta = target - current;
    if (delta.abs() < 0.5) return false;

    if (delta > 0) {
      var needed = delta;
      for (final i in _resizeOrder(visible, index)) {
        final min = widget.children[i].minSize;
        final available = (sizes[i] ?? 0) - min;
        if (available <= 0) continue;
        final take = math.min(available, needed);
        sizes[i] = (sizes[i] ?? 0) - take;
        needed -= take;
        if (needed <= 0.5) break;
      }
      final actual = delta - needed;
      if (actual <= 0.5) return false;
      sizes[index] = current + actual;
      return true;
    }

    var freed = -delta;
    final maxForIndex = child.maxSize ?? double.infinity;
    final shrinkRoom = current - child.minSize;
    freed = math.min(freed, shrinkRoom);
    if (freed <= 0.5) return false;

    var remaining = freed;
    for (final i in _resizeOrder(visible, index)) {
      final max = widget.children[i].maxSize ?? double.infinity;
      final available = max - (sizes[i] ?? 0);
      if (available <= 0) continue;
      final give = math.min(available, remaining);
      sizes[i] = (sizes[i] ?? 0) + give;
      remaining -= give;
      if (remaining <= 0.5) break;
    }
    final actual = freed - remaining;
    if (actual <= 0.5) return false;
    sizes[index] = math.min(maxForIndex, current - actual);
    return true;
  }

  List<int> _resizeOrder(List<int> visible, int index) {
    final pos = visible.indexOf(index);
    if (pos < 0) return const <int>[];
    return <int>[
      if (pos + 1 < visible.length) visible[pos + 1],
      if (pos - 1 >= 0) visible[pos - 1],
      for (var i = pos + 2; i < visible.length; i++) visible[i],
      for (var i = pos - 2; i >= 0; i--) visible[i],
    ];
  }
}

class _AnimatedAxisBox extends StatelessWidget {
  const _AnimatedAxisBox({
    required this.axis,
    required this.size,
    required this.animate,
    required this.child,
  });

  final Axis axis;
  final double size;
  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: animate ? _kSplitAnimationDuration : Duration.zero,
      curve: _kSplitAnimationCurve,
      width: axis == Axis.horizontal ? size : null,
      height: axis == Axis.vertical ? size : null,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: child,
    );
  }
}

class _StaticDivider extends StatelessWidget {
  const _StaticDivider({
    required this.axis,
    required this.thickness,
    required this.color,
  });

  final Axis axis;
  final double thickness;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return axis == Axis.horizontal
        ? SizedBox(
          width: thickness,
          child: Center(child: Container(width: 1, color: color)),
        )
        : SizedBox(
          height: thickness,
          child: Center(child: Container(height: 1, color: color)),
        );
  }
}

class _Gutter extends StatefulWidget {
  const _Gutter({
    required this.axis,
    required this.thickness,
    required this.color,
    required this.leftDismissible,
    required this.rightDismissible,
    required this.leftLabel,
    required this.rightLabel,
    required this.onDrag,
    required this.onDragEnd,
    required this.onCollapseLeft,
    required this.onCollapseRight,
  });

  final Axis axis;
  final double thickness;
  final Color color;
  final bool leftDismissible;
  final bool rightDismissible;
  final String? leftLabel;
  final String? rightLabel;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback onCollapseLeft;
  final VoidCallback onCollapseRight;

  @override
  State<_Gutter> createState() => _GutterState();
}

class _GutterState extends State<_Gutter> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.axis == Axis.horizontal;
    final cursor =
        isHorizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow;
    final active = _hovered || _dragging;

    final hitThickness = widget.thickness;
    final lineColor =
        active
            ? widget.color.withValues(alpha: 0.95)
            : widget.color.withValues(alpha: 0.55);

    final line = AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      width: isHorizontal ? (active ? 2 : 1) : null,
      height: isHorizontal ? null : (active ? 2 : 1),
      color: lineColor,
    );

    // Chevron buttons appear only on hover (or while dragging-just-ended). The
    // arrow points toward the panel that will collapse, so the gesture reads
    // naturally — pushing it out of the way.
    final showButtons = _hovered && !_dragging;

    final buttons = <Widget>[
      if (widget.leftDismissible)
        _GutterChevron(
          axis: widget.axis,
          direction: isHorizontal ? _ChevronDir.left : _ChevronDir.up,
          tooltip:
              widget.leftLabel == null
                  ? 'Collapse panel'
                  : 'Collapse ${widget.leftLabel}',
          onTap: widget.onCollapseLeft,
        ),
      if (widget.rightDismissible) ...[
        const SizedBox(height: 4, width: 4),
        _GutterChevron(
          axis: widget.axis,
          direction: isHorizontal ? _ChevronDir.right : _ChevronDir.down,
          tooltip:
              widget.rightLabel == null
                  ? 'Collapse panel'
                  : 'Collapse ${widget.rightLabel}',
          onTap: widget.onCollapseRight,
        ),
      ],
    ];

    final overlay = AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: showButtons ? 1 : 0,
      child: IgnorePointer(
        ignoring: !showButtons,
        child:
            isHorizontal
                ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: buttons,
                )
                : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: buttons,
                ),
      ),
    );

    return MouseRegion(
      cursor: cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart:
            isHorizontal ? (_) => setState(() => _dragging = true) : null,
        onHorizontalDragUpdate:
            isHorizontal ? (d) => widget.onDrag(d.delta.dx) : null,
        onHorizontalDragEnd:
            isHorizontal
                ? (_) {
                  setState(() => _dragging = false);
                  widget.onDragEnd();
                }
                : null,
        onVerticalDragStart:
            isHorizontal ? null : (_) => setState(() => _dragging = true),
        onVerticalDragUpdate:
            isHorizontal ? null : (d) => widget.onDrag(d.delta.dy),
        onVerticalDragEnd:
            isHorizontal
                ? null
                : (_) {
                  setState(() => _dragging = false);
                  widget.onDragEnd();
                },
        child: SizedBox(
          width: isHorizontal ? hitThickness : null,
          height: isHorizontal ? null : hitThickness,
          child: Stack(
            alignment: Alignment.center,
            children: [Center(child: line), overlay],
          ),
        ),
      ),
    );
  }
}

enum _ChevronDir { left, right, up, down }

class _GutterChevron extends StatefulWidget {
  const _GutterChevron({
    required this.axis,
    required this.direction,
    required this.tooltip,
    required this.onTap,
  });

  final Axis axis;
  final _ChevronDir direction;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_GutterChevron> createState() => _GutterChevronState();
}

class _GutterChevronState extends State<_GutterChevron> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final icon = switch (widget.direction) {
      _ChevronDir.left => Icons.chevron_left,
      _ChevronDir.right => Icons.chevron_right,
      _ChevronDir.up => Icons.expand_less,
      _ChevronDir.down => Icons.expand_more,
    };
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: DesktopTooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: (_hover ? kWhiteColor : kLightGreyColor).withValues(
                alpha: _hover ? 0.18 : 0.10,
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Icon(icon, size: 14, color: kWhiteColor70),
          ),
        ),
      ),
    );
  }
}

class _CollapsedRail extends StatefulWidget {
  const _CollapsedRail({
    required this.axis,
    required this.thickness,
    required this.label,
    required this.icon,
    required this.animate,
    required this.onExpand,
  });

  final Axis axis;
  final double thickness;
  final String? label;
  final IconData icon;
  final bool animate;
  final VoidCallback onExpand;

  @override
  State<_CollapsedRail> createState() => _CollapsedRailState();
}

class _CollapsedRailState extends State<_CollapsedRail> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.axis == Axis.horizontal;
    final label = _restoreLabel(widget.label);

    final rail = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        color: _hover ? kBlack2Color : kBlack2Color.withValues(alpha: 0.62),
        child: Center(
          child: TweenAnimationBuilder<double>(
            key: ValueKey('${widget.axis}:${widget.label}:${widget.icon}'),
            tween: Tween<double>(begin: widget.animate ? 0 : 1, end: 1),
            duration: widget.animate ? _kSplitAnimationDuration : Duration.zero,
            curve: _kSplitAnimationCurve,
            builder: (context, value, child) {
              final eased = value.clamp(0.0, 1.0);
              return Opacity(
                opacity: eased,
                child: Transform.scale(
                  scale: 0.86 + (0.14 * eased),
                  child: child,
                ),
              );
            },
            child: _CollapsedPaneButton(
              icon: widget.icon,
              label: label,
              hovered: _hover,
              onPressed: widget.onExpand,
            ),
          ),
        ),
      ),
    );

    return AnimatedContainer(
      duration: widget.animate ? _kSplitAnimationDuration : Duration.zero,
      curve: _kSplitAnimationCurve,
      width: isHorizontal ? widget.thickness : null,
      height: isHorizontal ? null : widget.thickness,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: rail,
    );
  }
}

class _CollapsedPaneButton extends StatelessWidget {
  const _CollapsedPaneButton({
    required this.icon,
    required this.label,
    required this.hovered,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool hovered;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: 'Show $label',
        child: SizedBox.square(
          dimension: 40,
          child: FButton.icon(
            style: _collapsedPaneButtonStyle(highlighted: hovered),
            onPress: onPressed,
            child: Icon(icon),
          ),
        ),
      ),
    );
  }
}

String _restoreLabel(String? label) {
  final trimmed = label?.trim();
  if (trimmed == null || trimmed.isEmpty) return 'panel';
  return trimmed;
}

IconData _fallbackCollapsedIcon(String? label) {
  switch (label?.trim().toLowerCase()) {
    case 'games':
      return Icons.view_list_rounded;
    case 'analysis':
      return Icons.analytics_outlined;
    case 'notation':
      return Icons.format_list_numbered_rounded;
    case 'engine':
      return Icons.memory_rounded;
    case 'board':
      return Icons.grid_on_rounded;
    default:
      return Icons.tab_unselected_rounded;
  }
}

FBaseButtonStyle Function(FButtonStyle style) _collapsedPaneButtonStyle({
  required bool highlighted,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kPrimaryColor.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.46)),
          boxShadow: [
            BoxShadow(
              color: kPrimaryColor.withValues(alpha: 0.12),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        WidgetState.any: BoxDecoration(
          color:
              highlighted
                  ? kBlack3Color.withValues(alpha: 0.94)
                  : kBlack3Color.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                highlighted
                    ? kWhiteColor.withValues(alpha: 0.16)
                    : kWhiteColor.withValues(alpha: 0.08),
          ),
        ),
      }),
      iconContentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.all(10),
            iconStyle: FWidgetStateMap({
              WidgetState.disabled: IconThemeData(
                color: kWhiteColor.withValues(alpha: 0.28),
                size: 18,
              ),
              WidgetState.hovered | WidgetState.pressed: const IconThemeData(
                color: kLightYellowColor,
                size: 18,
              ),
              WidgetState.any: IconThemeData(
                color: highlighted ? kWhiteColor : kWhiteColor70,
                size: 18,
              ),
            }),
          ),
    ),
  );
}
