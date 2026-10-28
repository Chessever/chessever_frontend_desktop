import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Keeps a tab/page subtree mounted while it is inactive.
///
/// Use this for children of PageView/TabBarView-style hosts where rebuilding an
/// inactive tab would discard controllers, scroll positions, filters, or form
/// state. Pass a PageStorageKey when scroll position should also be restored
/// after route-level rebuilds.
class PersistentTabPage extends StatefulWidget {
  const PersistentTabPage({super.key, required this.child});

  final Widget child;

  @override
  State<PersistentTabPage> createState() => _PersistentTabPageState();
}

class _PersistentTabPageState extends State<PersistentTabPage>
    with AutomaticKeepAliveClientMixin<PersistentTabPage> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// IndexedStack variant for app-level tabs.
///
/// All children stay mounted, while inactive children have tickers and focus
/// disabled so background tabs do not keep animating or stealing keyboard
/// focus. Direct children are keyed from the child's own key so inserting,
/// closing, or reordering a tab does not remount every later child — a
/// grandchild ValueKey cannot move across an unkeyed TickerMode parent.
class PersistentIndexedStack extends StatelessWidget {
  const PersistentIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.alignment = AlignmentDirectional.topStart,
    this.textDirection,
    this.sizing = StackFit.loose,
    this.clipBehavior = Clip.hardEdge,
  });

  final int? index;
  final List<Widget> children;
  final AlignmentGeometry alignment;
  final TextDirection? textDirection;
  final StackFit sizing;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    // Built as a keyed Stack rather than IndexedStack. Flutter's
    // IndexedStack wraps every child in an unkeyed _VisibilityScope, so a
    // ValueKey on our TickerMode (or on the grandchild pane) cannot follow
    // the child across insert/close/reorder — later Board tabs remount and
    // their live-stream players restart. Direct Stack children can carry
    // that identity. Hidden slots stay Offstage so they never paint or take
    // hits; pane_keyboard_scroll already skips offstage subtrees.
    //
    // Offstage alone still lays out its child at the live constraints, and
    // MediaQuery still rebuilds every dependent, so each window-resize frame
    // used to re-lay-out and partly rebuild every hidden tab. Hidden slots now
    // keep the constraints and MediaQuery they last had; the slot catches up
    // in the frame it becomes visible again.
    return Stack(
      alignment: alignment,
      textDirection: textDirection,
      fit: sizing,
      clipBehavior: clipBehavior,
      children: [
        for (var i = 0; i < children.length; i++)
          TickerMode(
            key: _PersistentStackChildKey(children[i].key, i),
            enabled: index == i,
            child: Offstage(
              offstage: index != i,
              child: _FreezeLayoutWhenHidden(
                frozen: index != i,
                child: _FreezeMediaQueryWhenHidden(
                  frozen: index != i,
                  child: ExcludeFocus(
                    excluding: index != i,
                    child: children[i],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Lays its child out at the last constraints it saw while [frozen].
///
/// A clean child laid out at unchanged constraints returns immediately, so a
/// hidden tab costs nothing when the window resizes. Unfreezing marks the
/// slot dirty and the child gets the live constraints in that same frame.
class _FreezeLayoutWhenHidden extends SingleChildRenderObjectWidget {
  const _FreezeLayoutWhenHidden({required this.frozen, super.child});

  final bool frozen;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFreezeLayout(frozen);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFreezeLayout renderObject,
  ) {
    renderObject.frozen = frozen;
  }
}

class _RenderFreezeLayout extends RenderProxyBox {
  _RenderFreezeLayout(this._frozen);

  bool _frozen;
  BoxConstraints? _lastConstraints;
  Size? _lastChildSize;

  set frozen(bool value) {
    if (value == _frozen) return;
    _frozen = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    final frozenConstraints = _lastConstraints;
    if (_frozen && frozenConstraints != null) {
      // The parent Offstage ignores this size, and reading child.size here
      // without parentUsesSize would trip a debug assertion, so report the
      // last measured size clamped to the live constraints.
      child?.layout(frozenConstraints);
      size = constraints.constrain(_lastChildSize ?? Size.zero);
      return;
    }
    _lastConstraints = constraints;
    if (child == null) {
      size = _lastChildSize = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = _lastChildSize = child.size;
  }
}

/// Hands descendants the MediaQuery they last saw while [frozen], so a
/// hidden tab's MediaQuery dependents do not rebuild on every resize frame.
/// Always inserts a MediaQuery so the tree shape (and tab state) never
/// changes when the slot hides or shows.
class _FreezeMediaQueryWhenHidden extends StatefulWidget {
  const _FreezeMediaQueryWhenHidden({
    required this.frozen,
    required this.child,
  });

  final bool frozen;
  final Widget child;

  @override
  State<_FreezeMediaQueryWhenHidden> createState() =>
      _FreezeMediaQueryWhenHiddenState();
}

class _FreezeMediaQueryWhenHiddenState
    extends State<_FreezeMediaQueryWhenHidden> {
  MediaQueryData? _frozenData;

  @override
  Widget build(BuildContext context) {
    // Only this small widget depends on the live MediaQuery. Returning the
    // same data and child while hidden stops the rebuild here.
    final live = MediaQuery.of(context);
    if (!widget.frozen) _frozenData = null;
    return MediaQuery(
      data: widget.frozen ? (_frozenData ??= live) : live,
      child: widget.child,
    );
  }
}

/// Identity for one IndexedStack slot. When the child has a key, that key
/// wins so the slot follows the child across reorder; otherwise the slot
/// stays at [fallbackIndex] like a plain IndexedStack.
@immutable
class _PersistentStackChildKey extends LocalKey {
  const _PersistentStackChildKey(this.childKey, this.fallbackIndex);

  final Key? childKey;
  final int fallbackIndex;

  @override
  bool operator ==(Object other) {
    return other is _PersistentStackChildKey &&
        other.childKey == childKey &&
        (childKey != null || other.fallbackIndex == fallbackIndex);
  }

  @override
  int get hashCode => childKey?.hashCode ?? fallbackIndex;
}
