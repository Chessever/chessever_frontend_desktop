import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('child optimism cannot manufacture a same-root positive moat', () {
    final game = ChessGame.fromPgn('same-root-red', '1. e4 *');
    final positions = [
      GameReportPosition(
        fen: game.startingFen,
        lines: const [
          GameReportLine(moves: ['e2e4'], depth: 18, centipawns: 20),
          GameReportLine(moves: ['d2d4'], depth: 18, centipawns: 19),
        ],
      ),
      GameReportPosition(
        fen: game.mainline.first.fen,
        lines: const [
          GameReportLine(moves: ['e7e5'], depth: 18, centipawns: 150),
        ],
      ),
    ];
    expect(
      buildGameAnalysisReport(
        game: game,
        fingerprint: 'x',
        positions: positions,
      ).moves.first.classification,
      isNull,
    );
  });
}
