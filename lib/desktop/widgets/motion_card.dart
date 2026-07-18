import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';

/// A quiet hover treatment for desktop cards.
///
/// The card's content is deliberately never transformed, scaled, or moved.
/// Fractional transforms force text glyphs through a different raster path on
/// every frame on some desktop renderers, which makes otherwise static labels
/// appear to shimmer. Instead, only a thin shell behind the card eases a small,
/// directional shadow while the content sits in its own repaint boundary.
///
/// [MotionCard] only observes direct hover. It intentionally has no proximity
/// behaviour: moving the pointer across a pane must not animate neighbouring
/// cards or create continuous work for every card in the view.
class MotionCard extends StatefulWidget {
  const MotionCard({
    super.key,
    required this.child,
    this.enabled = true,
    this.borderRadius = 12,
    this.onTap,
  });

  final Widget child;
  final bool enabled;

  /// Radius of the subtle shell shadow behind the card.
  final double borderRadius;

  /// Optional convenience tap. Cards with their own [GestureDetector] should
  /// leave this null and keep handling taps themselves.
  final VoidCallback? onTap;

  @override
  State<MotionCard> createState() => _MotionCardState();
}

class _MotionCardState extends State<MotionCard>
    with DeferredPointerStateMixin<MotionCard> {
  bool _hovered = false;

  void _setHovered(bool hovered) {
    if (!mounted || _hovered == hovered) return;
    setStateAfterPointerEvent(() => _hovered = hovered);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final content = RepaintBoundary(child: widget.child);
    final card = TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(end: _hovered ? 1 : 0),
      builder:
          (context, intensity, child) => DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              // A compact, downward contact shadow makes the shell feel responsive
              // without moving or re-rasterizing any content above it.
              boxShadow:
                  intensity == 0
                      ? null
                      : <BoxShadow>[
                        BoxShadow(
                          color: const Color(
                            0xFF000000,
                          ).withValues(alpha: 0.09 * intensity),
                          blurRadius: 4 * intensity,
                          offset: Offset(0, intensity),
                        ),
                      ],
            ),
            child: child,
          ),
      child: content,
    );

    Widget result = MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: card,
    );

    final onTap = widget.onTap;
    if (onTap != null) {
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: result,
      );
    }
    return result;
  }
}
