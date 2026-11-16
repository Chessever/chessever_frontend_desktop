import 'package:flutter/widgets.dart';

import 'package:chessever/theme/app_theme.dart';

/// A player's colour in one game of a match-play knockout: a small solid
/// White or Black square before the name.
///
/// Data, not ornament. In match play side A keeps one place for the whole
/// match (left in the header, top in every row), so position no longer says
/// who has White; this mark does. Every other list leaves it out.
class MatchPlayColorMark extends StatelessWidget {
  const MatchPlayColorMark({super.key, required this.isWhite, this.size = 9});

  final bool isWhite;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: isWhite ? 'White' : 'Black',
      excludeSemantics: true,
      child: SizedBox.square(
        key: ValueKey<String>(
          isWhite ? 'match-play-mark-white' : 'match-play-mark-black',
        ),
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isWhite ? kWhiteColor : kBlackColor,
            borderRadius: BorderRadius.circular(2),
            // Same 1 px edge on both so the squares are the same size; the
            // Black one needs it to read on the dark rail.
            border: Border.all(
              color:
                  isWhite ? kWhiteColor : kWhiteColor.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}
