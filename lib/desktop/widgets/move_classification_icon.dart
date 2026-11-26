import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';

/// The notation list's size for a move's class mark beside its SAN.
const double kMoveClassificationIconSize = 17;

/// The Game Report's mark for [classification], bare, with its name in a
/// tooltip: the badge the report rows and Toby's predicted moves draw.
///
/// Each badge SVG paints its own rounded square edge to edge, so nothing is
/// drawn behind it.
class MoveClassificationIcon extends StatelessWidget {
  const MoveClassificationIcon({
    super.key,
    required this.classification,
    this.size = kMoveClassificationIconSize,
  });

  final GameMoveClassification classification;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: classification.label,
      child: SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(
          classificationIconAsset(classification),
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
