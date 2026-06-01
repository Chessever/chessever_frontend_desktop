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
/// disabled so background tabs do not keep animating or stealing keyboard focus.
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
    return IndexedStack(
      index: index,
      alignment: alignment,
      textDirection: textDirection,
      sizing: sizing,
      clipBehavior: clipBehavior,
      children: [
        for (var i = 0; i < children.length; i++)
          TickerMode(
            enabled: index == i,
            child: ExcludeFocus(excluding: index != i, child: children[i]),
          ),
      ],
    );
  }
}
