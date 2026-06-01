import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Renders a project SVG icon at the given size, tinted with [color].
///
/// Use this everywhere across the desktop shell instead of Material icons
/// — the brand inventory under `assets/svgs/` is the canonical icon set,
/// not the random `Icons.*` glyphs the Flutter framework ships.
class DesktopIcon extends StatelessWidget {
  const DesktopIcon(
    this.assetPath, {
    super.key,
    this.size = 18,
    this.color,
  });

  final String assetPath;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      colorFilter:
          color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}
