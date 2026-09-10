import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/awarded_points.dart';

/// Presentation only: never rewrite the chess result or infer event rules.
double? desktopGamePoints(
  GameStatus status, {
  required bool isWhite,
  double? customPoints,
}) {
  if (!status.isFinished) return null;
  return parseAwardedPoints(customPoints) ??
      switch (status) {
        GameStatus.whiteWins => isWhite ? 1.0 : 0.0,
        GameStatus.blackWins => isWhite ? 0.0 : 1.0,
        GameStatus.draw => 0.5,
        _ => null,
      };
}

String desktopGamePointsLabel(
  GameStatus status, {
  required bool isWhite,
  double? customPoints,
}) {
  final points = desktopGamePoints(
    status,
    isWhite: isWhite,
    customPoints: customPoints,
  );
  if (points == null) return '';
  if (parseAwardedPoints(customPoints) == null && points == 0.5) return '½';
  return formatAwardedPoints(points);
}
