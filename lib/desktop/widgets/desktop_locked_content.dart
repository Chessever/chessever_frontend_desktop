import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

const ColorFilter _kGreyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// How far locked content is dimmed.
///
/// Locked content stays readable: at this value [kWhiteColor70] text keeps
/// about 6.5:1 on the page and 5:1 on a selected row's primary tint, so a
/// locked row can still be browsed, sorted and removed. The greyscale plus the
/// lock glyph carry the locked signal, not a dim that erases the text.
const double kDesktopLockedContentOpacity = 0.8;

/// Desaturates and dims [child] when [enabled]; otherwise returns it as is.
///
/// Draws premium-gated content as locked AT REST. Purely visual: it never
/// intercepts a pointer and never opens a paywall; the owning surface
/// re-evaluates access when the user acts.
///
/// Colour-coded text (results, titles) must be passed a neutral colour by the
/// caller while locked: the greyscale maps a saturated red or the brand primary
/// to a mid grey that no dim level keeps legible. Keep the [DesktopLockGlyph]
/// and any selection chrome outside this widget so they render at full
/// strength.
class DesktopDesaturated extends StatelessWidget {
  const DesktopDesaturated({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ColorFiltered(
      colorFilter: _kGreyscale,
      child: Opacity(opacity: kDesktopLockedContentOpacity, child: child),
    );
  }
}

/// The lock mark used on locked rows and cards. A bare glyph, no tile.
///
/// The explanation opens beside the glyph rather than above it: locks sit in
/// a table's first column or at a card's edge, where a centred tip would be
/// pushed against the window edge and over the row above.
class DesktopLockGlyph extends StatelessWidget {
  const DesktopLockGlyph({super.key, required this.reason, this.size = 14});

  final String reason;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: reason,
      tipAnchor: Alignment.centerLeft,
      childAnchor: Alignment.centerRight,
      child: Semantics(
        label: reason,
        child: Icon(Icons.lock_rounded, size: size, color: kWhiteColor70),
      ),
    );
  }
}
