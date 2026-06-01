import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderIndexedStack, RenderObject;
import 'package:flutter/services.dart';

/// Wraps the active pane content so PageUp / PageDown / Home / End
/// scroll the first vertical descendant `Scrollable` even when nothing
/// inside the pane has explicitly grabbed focus.
///
/// The shell's `FocusableActionDetector` autofocuses at boot, which
/// means descendant `Scrollable`s never receive keyboard events from
/// the default `WidgetsApp` shortcut map. Per-pane focus wrappers
/// (`ListKeyboardScrollFocus`) exist for a couple of panes; this
/// blanket wrapper covers every pane that did not opt in.
///
/// Arrow keys are intentionally left alone so panes with selection
/// based arrow navigation keep working.
class PaneKeyboardScroll extends StatefulWidget {
  const PaneKeyboardScroll({super.key, required this.child});

  final Widget child;

  @override
  State<PaneKeyboardScroll> createState() => _PaneKeyboardScrollState();
}

class _PaneKeyboardScrollState extends State<PaneKeyboardScroll> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'PaneKeyboardScroll',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    // Also listen at the HardwareKeyboard layer so PageUp / PageDown work
    // even when a descendant TextField (e.g. the pane's search field) has
    // primary focus. Flutter's default text-editing shortcuts route
    // PageUp/PageDown to `ScrollIntent`, which scrolls the nearest
    // Scrollable from `primaryFocus` — that resolves to the TextField's
    // own internal Scrollable, swallowing the keys before they can bubble
    // to this widget's `Focus.onKeyEvent`. Intercepting at the hardware
    // layer bypasses focus entirely. Home/End are left alone so they keep
    // moving the caret inside text fields.
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _focusNode.dispose();
    super.dispose();
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;
    final isPageDown = key == LogicalKeyboardKey.pageDown;
    final isPageUp = key == LogicalKeyboardKey.pageUp;
    if (!isPageDown && !isPageUp) return false;
    // Only intercept when a text field is focused — otherwise the existing
    // `Focus.onKeyEvent` path below (and any pane-specific shortcuts like
    // the board's "scroll notation" binding) handle the key correctly. We
    // only need to override the case where the focused TextField's own
    // ScrollIntent action would swallow the key into its caret scroll.
    if (!_primaryFocusIsTextField()) return false;
    final scrollable = _findScrollable();
    if (scrollable == null) return false;
    final viewport = scrollable.position.viewportDimension;
    _scrollBy(scrollable, isPageDown ? viewport * 0.9 : -viewport * 0.9);
    return true;
  }

  bool _primaryFocusIsTextField() {
    final node = FocusManager.instance.primaryFocus;
    final ctx = node?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  ScrollableState? _findScrollable() {
    // 1) Prefer the vertical Scrollable that is an ancestor of the currently
    //    focused widget. In split-view panes (Library, Board Settings,
    //    Opening Explorer) this routes PageUp/PageDown to whichever side the
    //    user is actually interacting with rather than always picking the
    //    DFS-first scrollable (which is usually the small left rail).
    final focusedCtx = FocusManager.instance.primaryFocus?.context;
    if (focusedCtx != null) {
      final preferred = _firstVerticalScrollableAncestor(focusedCtx);
      if (preferred != null &&
          preferred.position.hasContentDimensions &&
          preferred.position.maxScrollExtent > 0 &&
          _isDescendantOfThisPane(preferred)) {
        return preferred;
      }
    }

    // 2) Fall back to enumerating every vertical Scrollable under this pane
    //    and picking the one with the largest viewport. Largest viewport
    //    correlates with the main content area in master/detail layouts.
    final candidates = <ScrollableState>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      final renderObject = element.renderObject;
      if (renderObject is RenderIndexedStack) {
        final activeRenderChildren = <RenderObject>[];
        renderObject.visitChildrenForSemantics(activeRenderChildren.add);
        if (activeRenderChildren.isEmpty) return;
        final activeChild = _findElementForRenderObject(
          element,
          activeRenderChildren.first,
        );
        if (activeChild != null) visit(activeChild);
        return;
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        if (state.position.axis == Axis.vertical &&
            state.position.hasContentDimensions &&
            state.position.maxScrollExtent > 0) {
          candidates.add(state);
        }
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    if (candidates.isEmpty) return null;
    candidates.sort(
      (a, b) =>
          b.position.viewportDimension.compareTo(a.position.viewportDimension),
    );
    return candidates.first;
  }

  ScrollableState? _firstVerticalScrollableAncestor(BuildContext ctx) {
    ScrollableState? scrollable = Scrollable.maybeOf(ctx);
    while (scrollable != null) {
      if (scrollable.position.axis == Axis.vertical) return scrollable;
      // Walk up to the next Scrollable ancestor — the nearest one may be a
      // TextField's internal horizontal Scrollable.
      final parent =
          scrollable.context.findAncestorStateOfType<ScrollableState>();
      if (parent == null) return null;
      scrollable = parent;
    }
    return null;
  }

  bool _isDescendantOfThisPane(ScrollableState scrollable) {
    final paneCtx = context;
    final candidateCtx = scrollable.context;
    bool descendant = false;
    candidateCtx.visitAncestorElements((element) {
      if (element == paneCtx) {
        descendant = true;
        return false;
      }
      return true;
    });
    return descendant;
  }

  Element? _findElementForRenderObject(Element root, RenderObject target) {
    Element? found;
    void search(Element element) {
      if (found != null) return;
      if (element.renderObject == target) {
        found = element;
        return;
      }
      element.visitChildren(search);
    }

    root.visitChildren(search);
    return found;
  }

  void _scrollBy(ScrollableState scrollable, double delta) {
    final position = scrollable.position;
    final next = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.animateTo(
      next,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  void _scrollTo(ScrollableState scrollable, double offset) {
    scrollable.position.animateTo(
      offset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isPageDown = key == LogicalKeyboardKey.pageDown;
    final isPageUp = key == LogicalKeyboardKey.pageUp;
    final isHome = key == LogicalKeyboardKey.home;
    final isEnd = key == LogicalKeyboardKey.end;
    if (!isPageDown && !isPageUp && !isHome && !isEnd) {
      return KeyEventResult.ignored;
    }
    final scrollable = _findScrollable();
    if (scrollable == null) return KeyEventResult.ignored;
    if (isPageDown) {
      _scrollBy(scrollable, scrollable.position.viewportDimension * 0.9);
    } else if (isPageUp) {
      _scrollBy(scrollable, -scrollable.position.viewportDimension * 0.9);
    } else if (isHome) {
      _scrollTo(scrollable, scrollable.position.minScrollExtent);
    } else if (isEnd) {
      _scrollTo(scrollable, scrollable.position.maxScrollExtent);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      canRequestFocus: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}
