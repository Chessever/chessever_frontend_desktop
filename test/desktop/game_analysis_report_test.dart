import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('game report snapshots', () {
    final game = ChessGame.fromPgn(
      'report-test',
      '[White "Ada"]\n[Black "Grace"]\n\n1. e4 e5 2. Nf3 *',
    );

    test('fingerprint and FEN list follow only the mainline', () {
      expect(gameReportFingerprint(game), contains('e2e4 e7e5 g1f3'));
      expect(gameReportFens(game), hasLength(game.mainline.length + 1));
      expect(gameReportFens(game).first, game.startingFen);
      expect(gameReportFens(game).last, game.mainline.last.fen);
    });

    test('fingerprint changes when the mainline changes', () {
      final shorter = game.copyWith(mainline: game.mainline.take(2).toList());
      expect(
        gameReportFingerprint(shorter),
        isNot(gameReportFingerprint(game)),
      );
    });
  });

  group('report score calculations', () {
    test('mate and centipawn scores convert to white win percentage', () {
      expect(gameReportWinPercentage(_line(mate: 2)), 100);
      expect(gameReportWinPercentage(_line(mate: -2)), 0);
      expect(gameReportWinPercentage(_line(cp: 0)), closeTo(50, 0.001));
      expect(
        gameReportWinPercentage(_line(cp: 300)),
        greaterThan(gameReportWinPercentage(_line(cp: 100))),
      );
    });

    test('accuracy remains finite and penalizes a large loss', () {
      final steady = computeGameReportAccuracy([50, 50, 50, 50, 50]);
      final blunder = computeGameReportAccuracy([50, 10, 10, 10, 10]);
      expect(steady.white, closeTo(100, 0.1));
      expect(blunder.white, lessThan(steady.white));
      expect(blunder.black, inInclusiveRange(0, 100));
    });

    test('estimated ratings require moves by both players', () {
      expect(
        computeGameReportEstimatedRatings([_position(0), _position(10)]),
        isNull,
      );
      final ratings = computeGameReportEstimatedRatings(
        [_position(0), _position(-20), _position(15)],
        whiteRating: 1800,
        blackRating: 1750,
      );
      expect(ratings, isNotNull);
      expect(ratings!.white, inInclusiveRange(100, 3500));
      expect(ratings.black, inInclusiveRange(100, 3500));
    });

    test('terminal checkmate and draw positions need no engine result', () {
      final mate = terminalGameReportPosition('7k/6Q1/6K1/8/8/8/8/8 b - - 0 1');
      final draw = terminalGameReportPosition('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1');
      expect(mate?.bestLine.mate, 1);
      expect(draw?.bestLine.centipawns, 0);
    });
  });

  group('move classification', () {
    final game = ChessGame.fromPgn('classify', '1. e4 *');

    test('covers basic win-loss thresholds', () {
      expect(_classify(game, 50, 49), isNull);
      expect(_classify(game, 50, 47), isNull);
      expect(_classify(game, 50, 43), GameMoveClassification.inaccuracy);
      expect(_classify(game, 50, 38), GameMoveClassification.mistake);
      expect(_classify(game, 50, 25), GameMoveClassification.blunder);
    });

    test('best and forced take precedence over score thresholds', () {
      expect(
        _classify(game, 50, 20, bestMove: 'e2e4'),
        GameMoveClassification.bestMove,
      );
      expect(
        _classify(game, 50, 20, alternatives: false),
        GameMoveClassification.forced,
      );
    });

    test('only-good-move heuristic produces Perfect', () {
      final positions = [
        GameReportPosition(
          fen: game.startingFen,
          lines: [
            _line(cp: 0, moves: ['a2a3']),
            _line(cp: -250, moves: ['h2h3']),
          ],
        ),
        GameReportPosition(
          fen: game.mainline.first.fen,
          lines: [_line(cp: 150)],
        ),
      ];
      expect(
        classifyGameReportMove(
          index: 0,
          game: game,
          positions: positions,
          winPercentages: const [50, 70],
        ),
        GameMoveClassification.goodMove,
      );
    });

    test('losing a winning position produces Missed Win', () {
      expect(_classify(game, 80, 50), GameMoveClassification.missedWin);
    });

    test('sacrifice and simple-recapture guards inspect the board', () {
      expect(
        isReportPieceSacrifice(
          '4k3/8/8/8/1p6/8/3Q4/4K3 w - - 0 1',
          'd2c3',
          const ['b4c3'],
        ),
        isTrue,
      );
      expect(
        isSimpleReportRecapture(
          '4k3/8/2p5/3p4/4P3/8/8/4K3 w - - 0 1',
          'e4d5',
          'c6d5',
        ),
        isTrue,
      );
    });
  });
}

GameMoveClassification? _classify(
  ChessGame game,
  double before,
  double after, {
  String bestMove = 'a2a3',
  bool alternatives = true,
}) {
  final lines = [
    _line(cp: 0, moves: [bestMove]),
    if (alternatives) _line(cp: 0, moves: const ['h2h3']),
  ];
  return classifyGameReportMove(
    index: 0,
    game: game,
    positions: [
      GameReportPosition(fen: game.startingFen, lines: lines),
      GameReportPosition(fen: game.mainline.first.fen, lines: [_line(cp: 0)]),
    ],
    winPercentages: [before, after],
  );
}

GameReportPosition _position(int cp) => GameReportPosition(
  fen: '8/8/8/8/8/8/8/8 w - - 0 1',
  lines: [_line(cp: cp)],
);

GameReportLine _line({int? cp, int? mate, List<String> moves = const []}) =>
    GameReportLine(moves: moves, depth: 16, centipawns: cp, mate: mate);
