/// Accept only finite numeric awards. Missing or malformed is not zero.
double? parseAwardedPoints(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

String formatAwardedPoints(double value) =>
    value == value.truncateToDouble()
        ? value.toInt().toString()
        : value.toString();
