import 'package:flutter/painting.dart';

/// Stable per-line colours for engine PV arrows.
///
/// Keep this in rank order so the first engine row maps to the first board
/// arrow, the second row to the second arrow, and so on.
const List<Color> enginePvArrowPalette = <Color>[
  Color.fromARGB(220, 152, 179, 154),
  Color.fromARGB(220, 100, 149, 237),
  Color.fromARGB(220, 255, 165, 0),
  Color.fromARGB(220, 255, 105, 180),
  Color.fromARGB(220, 147, 112, 219),
];

Color enginePvArrowColor(int index) {
  final safeIndex = index < 0 ? 0 : index;
  return enginePvArrowPalette[safeIndex % enginePvArrowPalette.length];
}
