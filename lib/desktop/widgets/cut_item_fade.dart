import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:chessever/theme/app_theme.dart';

/// A scrolling list whose bottom edge never slices a row flat.
///
/// Wrap the list's scroll view in a [CutItemFade] and each column of rows
/// inside it in a [CutFadeItems]. When the bottom edge cuts through a row
/// (or a line under the rows), that row dissolves into the pane from its
/// visible top down to the edge, so it reads as the list going on. A row
/// with less than [CutItemFade.minVisibleShare] of it on screen is covered
/// whole instead, so the tops of its glyphs never smear along the edge.
/// Rows that fit whole are untouched, and nothing fades when the edge falls
/// between two rows.
///
/// The engine pane's Stockfish lines and its What Toby Thinks rows both use
/// it, so the two lists end the same way.
class CutItemFade extends StatefulWidget {
  const CutItemFade({
    super.key,
    required this.child,
    this.color = kBlack2Color,
  });

  final Widget child;

  /// The pane the cut row dissolves into.
  final Color color;

  /// Below this share of its height on screen, a cut row is covered whole.
  static const double minVisibleShare = 0.75;

  @override
  State<CutItemFade> createState() => _CutItemFadeState();
}

class _CutItemFadeState extends State<CutItemFade> {
  final _FadeItemGroups _groups = _FadeItemGroups();

  @override
  void dispose() {
    _groups.dispose();
    super.dispose();
  }

  bool _moved(Notification _) {
    _groups.moved();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return _FadeScope(
      groups: _groups,
      child: NotificationListener<ScrollNotification>(
        onNotification: _moved,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: _moved,
          child: _CutItemFade(
            groups: _groups,
            color: widget.color,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Marks its child's children (a column's) as rows the nearest
/// [CutItemFade]'s bottom edge may cut. [gap] is the space each row but the
/// last carries under it, which is not part of the row.
class CutFadeItems extends SingleChildRenderObjectWidget {
  const CutFadeItems({super.key, this.gap = 0, required super.child});

  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFadeItems(_FadeScope.of(context), gap);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderFadeItems)
      ..groups = _FadeScope.of(context)
      ..gap = gap;
  }
}

class _FadeScope extends InheritedWidget {
  const _FadeScope({required this.groups, required super.child});

  final _FadeItemGroups groups;

  static _FadeItemGroups of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_FadeScope>();
    assert(scope != null, 'CutFadeItems must sit inside a CutItemFade.');
    return scope!.groups;
  }

  @override
  bool updateShouldNotify(_FadeScope old) => !identical(old.groups, groups);
}

/// The groups of rows under one fade, and the signal that they moved: the
/// list scrolled, or its content changed size.
class _FadeItemGroups extends ChangeNotifier {
  final Set<_RenderFadeItems> _groups = <_RenderFadeItems>{};

  void moved() => notifyListeners();
}

class _RenderFadeItems extends RenderProxyBox {
  _RenderFadeItems(this._groups, this.gap);

  _FadeItemGroups _groups;
  double gap;

  set groups(_FadeItemGroups value) {
    if (identical(value, _groups)) return;
    if (attached) {
      _groups._groups.remove(this);
      value._groups.add(this);
    }
    _groups = value;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _groups._groups.add(this);
  }

  @override
  void detach() {
    _groups._groups.remove(this);
    super.detach();
  }

  /// Each row and where it ends, in [ancestor]'s coordinates.
  Iterable<Rect> itemsIn(RenderBox ancestor) sync* {
    final items = <RenderBox>[];
    child?.visitChildren((item) {
      if (item is RenderBox) items.add(item);
    });
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (!item.attached || !item.hasSize) continue;
      final below = i < items.length - 1 ? gap : 0.0;
      final topLeft = item.localToGlobal(Offset.zero, ancestor: ancestor);
      yield Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        item.size.width,
        item.size.height - below,
      );
    }
  }
}

class _CutItemFade extends SingleChildRenderObjectWidget {
  const _CutItemFade({
    required this.groups,
    required this.color,
    required super.child,
  });

  final _FadeItemGroups groups;
  final Color color;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCutItemFade(groups, color);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCutItemFade renderObject,
  ) {
    renderObject
      ..groups = groups
      ..color = color;
  }
}

class _RenderCutItemFade extends RenderProxyBox {
  _RenderCutItemFade(this._groups, this._color);

  _FadeItemGroups _groups;
  Color _color;

  set groups(_FadeItemGroups value) {
    if (identical(value, _groups)) return;
    if (attached) {
      _groups.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _groups = value;
    markNeedsPaint();
  }

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _groups.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _groups.removeListener(markNeedsPaint);
    super.detach();
  }

  /// The row the bottom edge cuts, if any: its visible part, and whether
  /// so little of it shows that it is covered whole.
  (Rect, bool)? _cutItem() {
    final edge = size.height;
    for (final group in _groups._groups) {
      if (!group.attached) continue;
      for (final item in group.itemsIn(this)) {
        if (item.top < edge - 0.5 && item.bottom > edge + 0.5) {
          final visible = Rect.fromLTRB(
            item.left,
            item.top.clamp(0.0, edge),
            item.right,
            edge,
          );
          return (
            visible,
            edge - item.top < item.height * CutItemFade.minVisibleShare,
          );
        }
      }
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final found = _cutItem();
    if (found == null) return;
    final (cut, cover) = found;
    if (cut.height <= 0) return;
    final area = cut.shift(offset);
    final paint = Paint();
    if (cover) {
      // Too little left to read as a row: the edge falls clean.
      paint.color = _color;
    } else {
      paint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_color.withValues(alpha: 0), _color],
      ).createShader(area);
    }
    context.canvas.drawRect(area, paint);
  }
}
