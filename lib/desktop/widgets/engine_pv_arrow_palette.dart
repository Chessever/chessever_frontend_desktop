import 'package:flutter/painting.dart';

/// Stable per-line colours for engine PV arrows.
///
/// Keep this in rank order so the first engine row maps to the first board
/// arrow, the second row to the second arrow, and so on. The final alpha is
/// applied by [enginePvArrowColor] so visual priority comes from rank weight,
/// not from changing the established colour order.
const List<Color> enginePvArrowPalette = <Color>[
  Color(0xFF98B39A),
  Color(0xFF6495ED),
  Color(0xFFFFA500),
  Color(0xFFFF69B4),
  Color(0xFF9370DB),
];

/// Desktop board-arrow scale by engine rank: strongest line first, then
/// progressively quieter. This preserves the max arrow count while making the
/// main recommendation immediately legible on a large board.
const List<double> enginePvArrowRankScales = <double>[
  1.0,
  0.86,
  0.74,
  0.64,
  0.55,
];

/// Desktop board-arrow opacity by engine rank. Keep lower-ranked arrows visible
/// enough on muted grey boards without letting them compete with the first PV.
const List<double> enginePvArrowRankAlphas = <double>[
  0.88,
  0.74,
  0.62,
  0.50,
  0.40,
];

Color enginePvArrowColor(int index) {
  final safeIndex = index < 0 ? 0 : index;
  final color = enginePvArrowPalette[safeIndex % enginePvArrowPalette.length];
  final alpha =
      safeIndex < enginePvArrowRankAlphas.length
          ? enginePvArrowRankAlphas[safeIndex]
          : enginePvArrowRankAlphas.last;
  return color.withValues(alpha: alpha);
}

double enginePvArrowScale(int index) {
  final safeIndex = index < 0 ? 0 : index;
  return safeIndex < enginePvArrowRankScales.length
      ? enginePvArrowRankScales[safeIndex]
      : enginePvArrowRankScales.last;
}
