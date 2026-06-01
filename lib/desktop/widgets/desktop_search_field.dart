import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop search field — square edges, dark chrome, ⌘+F-friendly. Used inside
/// pane chrome (Tournaments, Library, Calendar, Favorites, Countrymen) so each
/// pane has consistent search affordance without each one re-implementing the
/// same Container + TextField scaffolding.
class DesktopSearchField extends StatefulWidget {
  const DesktopSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hintText = 'Search…',
    this.autofocus = false,
    this.trailing,
    this.onClear,
    this.maxWidth = double.infinity,
    this.focusNode,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;
  final bool autofocus;
  final Widget? trailing;

  /// If provided, a clear (×) button is shown when text is non-empty. The
  /// callback is responsible for clearing both the controller text and any
  /// upstream search-query state.
  final VoidCallback? onClear;
  final double maxWidth;

  /// Optional external focus node. When supplied, the field defers ownership
  /// to the caller (used by surfaces that need to drive popovers off focus
  /// changes). Otherwise the field allocates and owns one internally.
  final FocusNode? focusNode;

  @override
  State<DesktopSearchField> createState() => _DesktopSearchFieldState();
}

class _DesktopSearchFieldState extends State<DesktopSearchField> {
  bool _focused = false;
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant DesktopSearchField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      // Swap listener targets; only dispose the node we own.
      (old.focusNode ?? _ownedFocusNode)?.removeListener(_handleFocusChange);
      _focusNode.addListener(_handleFocusChange);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    setState(() => _focused = _focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.isNotEmpty;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      // Spring-eased focus glow: when the user enters the field a soft
      // primary-tinted halo blooms around the border, then settles. Done
      // with motor's spring rather than a duration tween so the glow
      // responds to rapid tab-jumps without timing artifacts.
      child: SingleMotionBuilder(
        value: _focused ? 1.0 : 0.0,
        motion: DesktopMotion.layout,
        builder: (context, t, child) {
          return Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Color.lerp(kDividerColor, kPrimaryColor, t)!,
                width: 1 + 0.2 * t,
              ),
              boxShadow: t > 0.02
                  ? [
                      BoxShadow(
                        color: kPrimaryColor.withValues(alpha: 0.18 * t),
                        blurRadius: 12 * t,
                      ),
                    ]
                  : null,
            ),
            child: child,
          );
        },
        child: Row(
          children: [
            const Icon(Icons.search, size: 16, color: kLightGreyColor),
            const SizedBox(width: 10),
            Expanded(
              child: Shortcuts(
                shortcuts: const <ShortcutActivator, Intent>{
                  // Don't let Cmd+W / Cmd+T / Cmd+B etc. bubble while typing —
                  // matches what most apps do for inputs.
                  SingleActivator(LogicalKeyboardKey.escape):
                      DismissIntent(),
                },
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    DismissIntent: CallbackAction<DismissIntent>(
                      onInvoke: (_) {
                        if (widget.controller.text.isEmpty) return null;
                        widget.controller.clear();
                        widget.onChanged('');
                        widget.onClear?.call();
                        return null;
                      },
                    ),
                  },
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    autofocus: widget.autofocus,
                    onChanged: (v) {
                      widget.onChanged(v);
                      // Keep clear button in sync with text changes.
                      setState(() {});
                    },
                    cursorColor: kPrimaryColor,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: widget.hintText,
                      hintStyle: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (hasText)
              _ClearButton(
                onTap: () {
                  widget.controller.clear();
                  widget.onChanged('');
                  widget.onClear?.call();
                  setState(() {});
                },
              ),
            if (widget.trailing != null) ...[
              const SizedBox(width: 6),
              widget.trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _ClearButton extends StatefulWidget {
  const _ClearButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ClearButton> createState() => _ClearButtonState();
}

class _ClearButtonState extends State<_ClearButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.85 : (_hovered ? 1.1 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.close_rounded,
                size: 12,
                color: _hovered ? kWhiteColor : kLightGreyColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
