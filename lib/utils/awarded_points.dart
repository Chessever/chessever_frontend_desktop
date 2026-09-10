/// Accept only finite numeric awards. Missing or malformed is not zero.
double? parseAwardedPoints(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

/// Chess notation for scores: whole numbers plain, halves as `½` / `1½`, any
/// other award (a fraction some event rule produced) with two decimals so a
/// team sum never prints floating-point noise like `1.2000000000000002`.
String formatAwardedPoints(double value) {
  final rounded = (value * 100).roundToDouble() / 100;
  final whole = rounded.truncate();
  final fraction = rounded - whole;
  if (fraction == 0) return whole.toString();
  if (fraction == 0.5) return whole == 0 ? '½' : '$whole½';
  return rounded.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}
