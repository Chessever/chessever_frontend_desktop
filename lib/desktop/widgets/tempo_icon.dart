import 'package:flutter/material.dart';

import 'package:chessever/utils/png_asset.dart';

/// Resolves a local/desktop time-control category to a dedicated asset.
///
/// Bullet and ultra-bullet use their own icons (not the blitz art). Unknown
/// categories fall back to classical so callers always get a valid path.
String tempoIconAssetForCategory(String? category) {
  switch ((category ?? '').trim().toLowerCase()) {
    case 'classical':
    case 'standard':
      return PngAsset.classicalIcon;
    case 'rapid':
      return PngAsset.rapidIcon;
    case 'blitz':
      return PngAsset.blitzIcon;
    case 'bullet':
      return PngAsset.bulletIcon;
    case 'ultrabullet':
    case 'ultra_bullet':
    case 'ultra-bullet':
    case 'ultra bullet':
      return PngAsset.ultraBulletIcon;
    default:
      return PngAsset.classicalIcon;
  }
}

/// Square tempo glyph with [BoxFit.contain] so non-square source art is never
/// stretched (the old blitz asset was 44×64 and looked widened in a square box).
class TempoIcon extends StatelessWidget {
  const TempoIcon({
    super.key,
    required this.category,
    this.size = 14,
    this.color,
  });

  final String? category;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final asset = tempoIconAssetForCategory(category);
    final image = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => Icon(Icons.timer_outlined, size: size),
    );
    if (color == null) return SizedBox(width: size, height: size, child: image);
    return SizedBox(
      width: size,
      height: size,
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(color!, BlendMode.srcIn),
        child: image,
      ),
    );
  }
}
