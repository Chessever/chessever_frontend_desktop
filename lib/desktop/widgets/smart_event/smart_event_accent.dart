import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// Stable per-criteria accent, ported from the phone's smart event card so a
/// saved smart event keeps the same hue on every device. Desktop only ever
/// uses it tonally (low-alpha surface tint and edge), never as a fill.
Color smartEventAccentColor(String stableKey) {
  const palette = <Color>[
    kPrimaryColor,
    Color(0xFF38BDF8),
    Color(0xFFA3E635),
    Color(0xFFF97316),
    Color(0xFFF472B6),
    Color(0xFF22C55E),
  ];
  final hash = stableKey.codeUnits.fold<int>(
    0,
    (value, unit) => (value * 31 + unit) & 0x7fffffff,
  );
  return palette[hash % palette.length];
}
