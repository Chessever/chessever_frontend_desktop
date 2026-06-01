import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps a scrollable region (typically a `ListView`) with keyboard
/// arrow-scrolling. Up / Down move by [step] pixels, PageUp / PageDown
/// jump by the viewport height, Home / End hop to the extremes.
///
/// This is intentionally focus-passive — it does not autofocus. The user
/// reaches it by clicking anywhere in the list area (the underlying tap
/// regions still get their clicks because this only intercepts key
/// events, not pointer events).
///
/// Use this for panes whose lists *only* need arrow scrolling — the
/// Tournaments pane already implements its own selection-based arrow
/// nav (#461), so wrapping it again would be redundant.
class ListKeyboardScrollFocus extends StatefulWidget {
  const ListKeyboardScrollFocus({
    super.key,
    required this.controller,
    required this.child,
    this.step = 56,
    this.autofocus = false,
    this.enabled = true,
  });

  final ScrollController controller;
  final Widget child;
  final double step;

  /// Pull focus on first attach so arrow keys work without a click.
  /// Off by default to avoid stealing focus from text fields, but on
  /// when the pane has no competing focusable input.
  final bool autofocus;

  /// When false, key events pass through to ancestor handlers.
  final bool enabled;

  @override
  State<ListKeyboardScrollFocus> createState() =>
      _ListKeyboardScrollFocusState();
}

class _ListKeyboardScrollFocusState extends State<ListKeyboardScrollFocus> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'ListKeyboardScrollFocus',
  );

  @override
  void didUpdateWidget(covariant ListKeyboardScrollFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled && widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    final controller = widget.controller;
    if (!controller.hasClients) return;
    final next = (controller.offset + delta).clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    controller.animateTo(
      next,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  void _scrollTo(double offset) {
    final controller = widget.controller;
    if (!controller.hasClients) return;
    controller.animateTo(
      offset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _scrollBy(widget.step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _scrollBy(-widget.step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      final controller = widget.controller;
      if (!controller.hasClients) return KeyEventResult.handled;
      _scrollBy(controller.position.viewportDimension * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      final controller = widget.controller;
      if (!controller.hasClients) return KeyEventResult.handled;
      _scrollBy(-controller.position.viewportDimension * 0.9);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      final controller = widget.controller;
      if (!controller.hasClients) return KeyEventResult.handled;
      _scrollTo(controller.position.minScrollExtent);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      final controller = widget.controller;
      if (!controller.hasClients) return KeyEventResult.handled;
      _scrollTo(controller.position.maxScrollExtent);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: true,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // Click anywhere in the list area to capture focus so the
        // arrow keys take effect immediately afterwards.
        onTapDown: (_) {
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
        },
        child: widget.child,
      ),
    );
  }
}
