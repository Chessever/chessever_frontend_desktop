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
    // that identity. Hidden slots stay Offstage so they layout at the
    // stack's constraints (same as IndexedStack) without painting or
    // taking hits; pane_keyboard_scroll already skips offstage subtrees.
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
              child: ExcludeFocus(excluding: index != i, child: children[i]),
            ),
          ),
      ],
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
