import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';

/// Packed interaction state for the dock spring.
class _Dock {
  const _Dock(this.scale, this.lift, this.elevation);
  final double scale;
  final double lift; // logical px the card rises (applied as -y)
  final double elevation; // 0..1 — drives shadow alpha / blur / offset
}

final MotionConverter<_Dock> _dockConverter = MotionConverter.custom(
  normalize: (_Dock d) => <double>[d.scale, d.lift, d.elevation],
  denormalize: (List<double> v) => _Dock(v[0], v[1], v[2]),
);

/// Provides the global cursor position to descendant [MotionCard]s so they
/// react to the cursor's *nearness* (a calm lift with distance falloff)
/// rather than binary hover. Mount once around a region of cards; a
/// [MotionCard] with no ancestor scope falls back to plain on/off hover.
///
/// Coordinates are global, so the scope can sit anywhere above the cards.
class CursorProximityScope extends StatefulWidget {
  const CursorProximityScope({super.key, required this.child});

  final Widget child;

  /// The global cursor position notifier for the nearest scope, or null if
  /// there is none above [context].
  static ValueListenable<Offset?>? of(BuildContext context) {
    final inherited =
        context.dependOnInheritedWidgetOfExactType<_CursorProximityInherited>();
    return inherited?.cursor;
  }

  @override
  State<CursorProximityScope> createState() => _CursorProximityScopeState();
}

class _CursorProximityScopeState extends State<CursorProximityScope> {
  final ValueNotifier<Offset?> _cursor = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // opaque:false so the region never blocks the cards' own hit testing; it
    // only listens. One ValueNotifier feeds every descendant card.
    return MouseRegion(
      opaque: false,
      hitTestBehavior: HitTestBehavior.translucent,
      onHover: (event) => _cursor.value = event.position,
      onExit:
          (_) => runAfterPointerEvent(() {
            if (!mounted) return;
            _cursor.value = null;
          }),
      child: _CursorProximityInherited(cursor: _cursor, child: widget.child),
    );
  }
}

class _CursorProximityInherited extends InheritedWidget {
  const _CursorProximityInherited({required this.cursor, required super.child});

  final ValueListenable<Offset?> cursor;

  @override
  bool updateShouldNotify(_CursorProximityInherited oldWidget) =>
      cursor != oldWidget.cursor;
}

/// Spring-driven interaction for desktop cards: scale + lift + spring
/// shadow.
///
/// Under a [CursorProximityScope] the card magnifies by the cursor's
/// *nearness* — multiple neighbours react at once with a smooth distance
/// falloff (`t = (1 - dist/radius)²`). Without a scope it falls back to binary
/// hover. Press always depresses and settles. All three properties travel as
/// one velocity-preserving motor spring, so an interrupted transition never
/// snaps.
///
/// Non-event-eating like [PressableScale]: installs a [MouseRegion] (hover /
/// fallback) and a translucent [Listener] (press) only, so the wrapped card
/// keeps its own gestures (tap, secondary-tap, `LongPressDraggable`, …).
class MotionCard extends StatefulWidget {
  const MotionCard({
    super.key,
    required this.child,
    this.enabled = true,
    this.depressOnPress = true,
    this.borderRadius = 12,
    this.hoverScale = 1.022,
    this.pressScale = 0.97,
    this.hoverLift = 7.0,
    this.proximityRadius = 150.0,
    this.shadowColor,
    this.onTap,
  });

  final Widget child;
  final bool enabled;

  /// When false, pointer-down no longer depresses the card (no press
  /// scale-down, no lift drop). Use for cards that *navigate on tap*: the
  /// press dock collapses [hoverLift] to 0, and that downward translation
  /// visibly shifts the card's content (e.g. a grid card's board preview)
  /// in the frame before the route/tab switch — reading as a glitch. With
  /// this off, the hover/proximity lift is held steady while the card is
  /// clicked, so nothing moves before navigation.
  final bool depressOnPress;

  /// Radius of the host card, so the spring drop-shadow hugs the tile.
  final double borderRadius;

  /// Scale at full intensity (cursor centred / direct hover).
  final double hoverScale;
  final double pressScale;

  /// Lift in logical px at full intensity.
  final double hoverLift;

  /// Influence radius in logical px: how near the cursor must be before the
  /// card starts reacting (proximity mode only). Larger → more neighbours
  /// light up together.
  final double proximityRadius;

  /// Shadow tint; defaults to [kPrimaryColor].
  final Color? shadowColor;

  /// Optional convenience tap. Cards with their own [GestureDetector] should
  /// leave this null and keep handling taps themselves.
  final VoidCallback? onTap;

  @override
  State<MotionCard> createState() => _MotionCardState();
}

class _MotionCardState extends State<MotionCard>
    with DeferredPointerStateMixin<MotionCard> {
  bool _hovered = false;
  bool _pressed = false;

  void _setInteractionState({bool? hovered, bool? pressed}) {
    if (!mounted) return;

    setStateAfterPointerEvent(() {
      final nextHovered = hovered ?? _hovered;
      final nextPressed = pressed ?? _pressed;
      if (nextHovered == _hovered && nextPressed == _pressed) return;
      _hovered = nextHovered;
      _pressed = nextPressed;
    });
  }

  /// Maps an intensity `t` in [0,1] (proximity nearness, or binary hover) plus
  /// the press flag to the dock target.
  _Dock _dockFor(double t) {
    if (!widget.enabled) return const _Dock(1, 0, 0);
    if (_pressed) {
      return _Dock(widget.pressScale, 0, 0.18);
    }
    final scale = 1 + (widget.hoverScale - 1) * t;
    return _Dock(scale, widget.hoverLift * t, t);
  }

  /// Proximity intensity for this card given a global cursor position: 1 at
  /// the card centre, easing to 0 at [MotionCard.proximityRadius].
  double _proximityIntensity(Offset cursorGlobal) {
    if (!mounted) return 0;

    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return 0;
    }

    try {
      final center = renderObject.localToGlobal(
        renderObject.size.center(Offset.zero),
      );
      final distance = (cursorGlobal - center).distance;
      final linear = (1 - distance / widget.proximityRadius).clamp(0.0, 1.0);
      return linear * linear; // ease-in falloff: quiet at the edges
    } on FlutterError {
      return 0;
    } on TypeError {
      return 0;
    }
  }

  Widget _dockBox(BuildContext context, _Dock d, Widget? child) {
    final shadowColor = widget.shadowColor ?? kPrimaryColor;
    return Transform.translate(
      offset: Offset(0, -d.lift),
      child: Transform.scale(
        scale: d.scale,
        // Rasterize the card (text + shadow) once and scale the BITMAP, rather
        // than letting Impeller re-shape glyphs at every fractional scale step.
        // That per-frame glyph reshaping is the hover "shimmer/titreme"
        // (flutter#149652, an Impeller text-transform rounding bug). Forcing a
        // non-null filterQuality switches Transform to the bitmap path → the
        // text stays rock-steady while the card zooms. At a ~2% hover scale the
        // bilinear softening is imperceptible.
        filterQuality: FilterQuality.medium,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            // Layered depth (make-interfaces-feel-better #3): a tight near-black
            // contact shadow grounds the tile while a soft, wide tinted bloom
            // sells the lift. Both scale with the spring's elevation so depth
            // grows fluidly with hover/proximity instead of popping in.
            boxShadow:
                d.elevation <= 0.001
                    ? null
                    : <BoxShadow>[
                      BoxShadow(
                        color: const Color(
                          0xFF000000,
                        ).withValues(alpha: 0.22 * d.elevation),
                        blurRadius: 10 * d.elevation,
                        offset: Offset(0, 4 * d.elevation),
                      ),
                      BoxShadow(
                        color: shadowColor.withValues(
                          alpha: 0.18 * d.elevation,
                        ),
                        blurRadius: 26 * d.elevation,
                        offset: Offset(0, 12 * d.elevation),
                      ),
                    ],
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final cursor = CursorProximityScope.of(context);
    final pinnedChild = RepaintBoundary(child: widget.child);

    final Widget motion;
    if (cursor != null) {
      // Proximity mode: rebuild on cursor move; target driven by nearness.
      motion = ListenableBuilder(
        listenable: cursor,
        builder: (context, _) {
          final c = cursor.value;
          final t = (_pressed || c == null) ? 0.0 : _proximityIntensity(c);
          return MotionBuilder<_Dock>(
            motion:
                _pressed
                    ? DesktopMotion.cardPress
                    : DesktopMotion.cardProximity,
            value: _dockFor(t),
            converter: _dockConverter,
            builder: _dockBox,
            child: pinnedChild,
          );
        },
      );
    } else {
      // Binary fallback: hover on/off via the card's own MouseRegion.
      motion = MotionBuilder<_Dock>(
        motion: _pressed ? DesktopMotion.cardPress : DesktopMotion.cardHover,
        value: _dockFor(_hovered ? 1.0 : 0.0),
        converter: _dockConverter,
        builder: _dockBox,
        child: pinnedChild,
      );
    }

    Widget content = MouseRegion(
      onEnter: (_) => _setInteractionState(hovered: true),
      onExit: (_) => _setInteractionState(hovered: false, pressed: false),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown:
            widget.depressOnPress
                ? (_) => _setInteractionState(pressed: true)
                : null,
        onPointerUp:
            widget.depressOnPress
                ? (_) => _setInteractionState(pressed: false)
                : null,
        onPointerCancel:
            widget.depressOnPress
                ? (_) => _setInteractionState(pressed: false)
                : null,
        child: motion,
      ),
    );

    final onTap = widget.onTap;
    if (onTap != null) {
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      );
    }
    return content;
  }
}
