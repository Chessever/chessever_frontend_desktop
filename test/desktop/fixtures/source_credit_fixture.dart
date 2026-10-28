import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

const credit = 'B Brkic,A (2642)-Valderrama,Q (2390) Olymp 2026 Open 2026';
const directive = '[%src $credit]';

ChessGame fixture({String footer = directive}) {
  final base = ChessGame.fromPgn(
    'trim-source-credit',
    '[Event "Original"]\n\n1. e4 e5 2. Nf3 Nc6 *',
  );
  final branch =
      ChessGame.fromPgn(
        'inserted',
        '[SetUp "1"]\n[FEN "${base.mainline.first.fen}"]\n\n1... c5 2. Nf3 {Selected note [%clk 0:12:34]} d6 {Deleted future prose $footer} *',
      ).mainline;
  return base.copyWith(
    mainline: [
      base.mainline.first.copyWith(
        variations: [branch],
        overrideVariations: true,
      ),
      ...base.mainline.skip(1),
    ],
  );
}
