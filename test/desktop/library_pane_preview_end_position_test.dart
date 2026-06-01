import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

// The library right-side preview renders DesktopGameCard(layout: grid). The
// card paints `GameCardData.fen`. To prove the preview shows the END position
// (not the start), pin GameCardData factory output for a multi-move analysis.

void main() {
  test(
    'GameCardData.fromSavedAnalysis exposes the final mainline FEN, not the '
    'starting FEN — DesktopGameCard renders this in the library preview',
    () {
      const startFen =
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      const afterE4Fen =
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
      const afterE4E5Fen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2';

      final analysis = SavedAnalysis(
        id: 'demo',
        userId: 'user',
        title: 'White vs Black',
        chessGame: ChessGame(
          gameId: 'demo',
          startingFen: startFen,
          metadata: const <String, dynamic>{
            'White': 'White',
            'Black': 'Black',
            'Result': '1-0',
          },
          mainline: [
            ChessMove(
              num: 1,
              uci: 'e2e4',
              san: 'e4',
              fen: afterE4Fen,
              turn: ChessColor.white,
            ),
            ChessMove(
              num: 1,
              uci: 'e7e5',
              san: 'e5',
              fen: afterE4E5Fen,
              turn: ChessColor.black,
            ),
          ],
        ),
        analysisState: const {},
        variationComments: const {},
        lastViewedPosition: -1,
        tags: const [],
        isFavorite: false,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );

      final card = GameCardData.fromSavedAnalysis(analysis);
      expect(card.fen, afterE4E5Fen);
      expect(card.fen, isNot(startFen));
      expect(card.hasStarted, isTrue);
      expect(card.status, GameStatus.whiteWins);
    },
  );

  test(
    'GameCardData.fromChessGame exposes the final mainline FEN for local '
    'preview cards rendered in the library local mini preview',
    () {
      const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      const afterE4Fen =
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

      final game = ChessGame(
        gameId: 'local',
        startingFen: startFen,
        metadata: const <String, dynamic>{
          'White': 'A',
          'Black': 'B',
          'Result': '0-1',
        },
        mainline: [
          ChessMove(
            num: 1,
            uci: 'e2e4',
            san: 'e4',
            fen: afterE4Fen,
            turn: ChessColor.white,
          ),
        ],
      );

      final card = GameCardData.fromChessGame(game);
      expect(card.fen, afterE4Fen);
      expect(card.status, GameStatus.blackWins);
    },
  );
}
