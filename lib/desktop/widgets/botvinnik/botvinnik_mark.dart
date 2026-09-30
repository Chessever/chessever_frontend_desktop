import 'package:flutter/widgets.dart';

/// Botvinnik's brand mark: the crowned speech bubble with round glasses.
///
/// The real asset the phone app ships, drawn untinted and without a tile or a
/// glow, so it reads as the product's identity rather than a stock glyph. It is
/// decoded at device resolution so it stays crisp at small logical sizes.
class BotvinnikMark extends StatelessWidget {
  const BotvinnikMark({super.key, required this.size});

  static const asset = 'assets/pngs/botvinnik_icon.png';

  final double size;

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      cacheWidth: (size * devicePixelRatio).round(),
      excludeFromSemantics: true,
    );
  }
}
