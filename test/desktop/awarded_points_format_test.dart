import 'package:chessever/desktop/widgets/desktop_game_points.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/awarded_points.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats awards in chess notation', () {
    expect(formatAwardedPoints(0), '0');
    expect(formatAwardedPoints(3), '3');
    expect(formatAwardedPoints(0.5), '½');
    expect(formatAwardedPoints(1.5), '1½');
    expect(formatAwardedPoints(1.25), '1.25');
    expect(formatAwardedPoints(1.2), '1.2');
    // A team sum accumulated in floating point must not leak its noise.
    expect(formatAwardedPoints(0.4 + 0.4 + 0.4), '1.2');
  });

  test('an awarded half point reads like a drawn half point', () {
    expect(
      desktopGamePointsLabel(
        GameStatus.whiteWins,
        isWhite: true,
        customPoints: 0.5,
      ),
      '½',
    );
    expect(desktopGamePointsLabel(GameStatus.draw, isWhite: false), '½');
    expect(
      desktopGamePointsLabel(GameStatus.draw, isWhite: true, customPoints: 2.5),
      '2½',
    );
  });
}
