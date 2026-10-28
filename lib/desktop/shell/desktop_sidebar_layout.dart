import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/shell/desktop_sidebar.dart';

/// Places [sidebar] beside [content] so a sidebar toggle re-lays out the
/// content once instead of on every animation frame.
///
/// [DesktopSidebar] animates its own width. In a plain `Row` the content beside
/// it was re-laid out at a new width on every frame of that animation, which
/// for a board, explorer and games table is far over a 120 Hz frame budget.
/// Here the sidebar paints above the content and the content's left inset
/// changes at most once per toggle:
///
/// - Collapsing: the content takes its wider final layout at once and the
///   shrinking sidebar uncovers it.
/// - Expanding: the growing sidebar slides over the content, and the content
///   takes its narrower layout when the animation ends.
class DesktopSidebarLayout extends StatefulWidget {
  const DesktopSidebarLayout({
    super.key,
    required this.sidebar,
    required this.content,
    required this.showSidebar,
    required this.expanded,
  });

  final Widget sidebar;
  final Widget content;

  /// False while board focus mode hides the sidebar.
  final bool showSidebar;

  /// Whether [sidebar] is (or is animating to) its expanded width.
  final bool expanded;

  @override
  State<DesktopSidebarLayout> createState() => _DesktopSidebarLayoutState();
}

class _DesktopSidebarLayoutState extends State<DesktopSidebarLayout> {
  late double _inset = _targetInset;
  Timer? _settle;

  double get _targetInset {
    if (!widget.showSidebar) return 0;
    return widget.expanded
        ? DesktopSidebar.expandedWidth
        : DesktopSidebar.collapsedWidth;
  }

  @override
  void didUpdateWidget(covariant DesktopSidebarLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _targetInset;
    if (target == _inset) {
      _settle?.cancel();
      return;
    }
    // A sidebar that just appeared has no width animation to wait for, and a
    // shrinking inset never exposes empty space, so both apply immediately.
    if (widget.showSidebar != oldWidget.showSidebar || target < _inset) {
      _settle?.cancel();
      _inset = target;
      return;
    }
    _settle?.cancel();
    _settle = Timer(DesktopSidebar.animationDuration, () {
      if (!mounted) return;
      setState(() => _inset = _targetInset);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: _inset,
          top: 0,
          right: 0,
          bottom: 0,
          child: widget.content,
        ),
        // Painted last so the animating sidebar covers the content, never the
        // other way round. Its width comes from DesktopSidebar itself.
        if (widget.showSidebar)
          Positioned(left: 0, top: 0, bottom: 0, child: widget.sidebar),
      ],
    );
  }
}
