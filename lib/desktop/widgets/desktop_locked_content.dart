import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

const ColorFilter _kGreyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Draws premium-gated content as locked AT REST: desaturated, dimmed, and
/// marked with a bare lock glyph that explains itself on hover.
///
/// Purely visual. It never intercepts a pointer and never opens a paywall;
/// the owning surface re-evaluates access when the user acts, and only an
/// explicit action may offer Premium. The content stays fully readable, so a
/// locked row can still be browsed, sorted and removed.
class DesktopLockedContent extends StatelessWidget {
  const DesktopLockedContent({
    super.key,
    required this.locked,
    required this.reason,
    required this.child,
    this.glyphAlignment = AlignmentDirectional.topEnd,
    this.glyphPadding = const EdgeInsetsDirectional.fromSTEB(0, 8, 10, 0),
  });

  final bool locked;

  /// Hover copy naming the specific rule, e.g. "Liked more than 7 days ago.
  /// Premium opens your full history."
  final String reason;
  final Widget child;
  final AlignmentGeometry glyphAlignment;
  final EdgeInsetsGeometry glyphPadding;

  @override
  Widget build(BuildContext context) {
    if (!locked) return child;
    return Stack(
      children: [
        DesktopDesaturated(enabled: true, child: child),
        Positioned.fill(
          child: Align(
            alignment: glyphAlignment,
            child: Padding(
              padding: glyphPadding,
              child: DesktopLockGlyph(reason: reason),
            ),
          ),
        ),
      ],
    );
  }
}

/// Desaturates and dims [child] when [enabled]; otherwise returns it as is.
/// Use where the lock glyph lives in its own column (table rows).
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
      child: Opacity(opacity: 0.62, child: child),
    );
  }
}

/// The lock mark used on locked rows and cards. A bare glyph, no tile.
class DesktopLockGlyph extends StatelessWidget {
  const DesktopLockGlyph({super.key, required this.reason, this.size = 14});

  final String reason;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: reason,
      child: Semantics(
        label: reason,
        child: Icon(Icons.lock_rounded, size: size, color: kWhiteColor70),
      ),
    );
  }
}
