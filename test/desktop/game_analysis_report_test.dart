import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
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

  group('report progress', () {
    test('visible running reports borrow the foreground board engine', () {
      expect(
        shouldRunLiveBoardAnalysis(
          isForeground: true,
          reportVisible: true,
          reportRunning: true,
        ),
        isFalse,
      );
      expect(
        shouldRunLiveBoardAnalysis(
          isForeground: true,
          reportVisible: false,
          reportRunning: true,
        ),
        isTrue,
      );
      expect(
        shouldRunLiveBoardAnalysis(
          isForeground: true,
          reportVisible: true,
          reportRunning: false,
        ),
        isTrue,
      );
      expect(
        shouldRunLiveBoardAnalysis(
          isForeground: false,
          reportVisible: false,
          reportRunning: false,
        ),
        isFalse,
      );
    });

    // Fake evaluator that mirrors Stockfish: it streams many info ticks with a
    // growing cumulative node count (several per depth) before returning, so
    // the controller reports sub-position progress the way it does live.
    Future<EnhancedCloudEval> deepeningEvaluator(
      String fen, {
      required int depth,
      required int multiPv,
      required String ownerId,
      void Function(int reachedDepth, int knodes)? onProgress,
    }) async {
      var knodes = 0;
      for (var d = 1; d <= depth; d++) {
        for (var tick = 0; tick < 4; tick++) {
          knodes += 25 * d; // nodes accumulate faster at deeper iterations
          onProgress?.call(d, knodes);
        }
      }
      return EnhancedCloudEval(
        fen: fen,
        knodes: knodes,
        depth: depth,
        pvs: [Pv(moves: 'e2e4', cp: 20)],
        requestedMultiPv: multiPv,
      );
    }

    test('advances within each search and never moves backwards', () async {
      final game = ChessGame.fromPgn('smooth', '1. e4 e5 2. Nf3 Nc6 *');
      final positionCount = gameReportFens(game).length;
      final controller = GameAnalysisReportController(
        evaluator: deepeningEvaluator,
      );
      addTearDown(controller.dispose);

      final progresses = <double>[];
      controller.addListener(() {
        if (controller.state.status == GameReportStatus.running) {
          progresses.add(controller.state.progress);
        }
      });

      await controller.analyze(game);

      expect(controller.state.status, GameReportStatus.completed);
      expect(controller.state.progress, 1.0);

      // Monotonic: the bar only ever eases forward.
      for (var i = 1; i < progresses.length; i++) {
        expect(progresses[i], greaterThanOrEqualTo(progresses[i - 1]));
      }

      // Sub-position granularity: far more updates than positions proves the
      // bar creeps *during* a search instead of only jumping when a whole
      // position finishes — the fix for the "stuck then jumps" stall.
      expect(progresses.length, greaterThan(positionCount * 2));
      expect(progresses.toSet().length, greaterThan(positionCount));
    });

    test('primary pass is MultiPV 1; MultiPV 3 only on refinement', () async {
      // Regression: full MultiPV-3 on every ply at depth 18 was slower than
      // mobile multipass. The shipped controller must spend MultiPV selectively.
      final game = ChessGame.fromPgn('multipass', '1. e4 e5 2. Nf3 Nc6 *');
      final multiPvByCall = <int>[];
      final depths = <int>[];

      Future<EnhancedCloudEval> recordingEvaluator(
        String fen, {
        required int depth,
        required int multiPv,
        required String ownerId,
        void Function(int reachedDepth, int knodes)? onProgress,
      }) async {
        multiPvByCall.add(multiPv);
        depths.add(depth);
        onProgress?.call(depth, 100);
        // Distinct first moves so MultiPV refinement can see alternatives.
        final pvs = <Pv>[
          Pv(moves: 'e2e4', cp: 20),
          if (multiPv > 1) Pv(moves: 'd2d4', cp: -30),
          if (multiPv > 2) Pv(moves: 'c2c4', cp: -40),
        ];
        return EnhancedCloudEval(
          fen: fen,
          knodes: 100,
          depth: depth,
          pvs: pvs,
          requestedMultiPv: multiPv,
        );
      }

      final controller = GameAnalysisReportController(
        evaluator: recordingEvaluator,
      );
      addTearDown(controller.dispose);
      await controller.analyze(game);

      expect(controller.state.status, GameReportStatus.completed);
      // First N calls are the primary single-PV sweep over positions.
      final positionCount = gameReportFens(game).length;
      expect(multiPvByCall.length, greaterThanOrEqualTo(positionCount));
      final primary = multiPvByCall.take(positionCount).toList();
      expect(
        primary.every((mpv) => mpv == 1),
        isTrue,
        reason: 'primary pass must be MultiPV 1, got $primary',
      );
      // Depth stays in the efficient band (not 18/22 everywhere).
      expect(
        depths.every((d) => d <= GameAnalysisReportController.brilliantDepth),
        isTrue,
      );
      expect(
        GameAnalysisReportController.reportDepth,
        lessThan(18),
        reason: 'primary depth should stay leaner than the over-spent 18',
      );
    });
  });

  group('move classification (mobile-parity lichess damage + praise)', () {
    final game = ChessGame.fromPgn('classify', '1. e4 *');

    test('lichess winning-chances table marks damage tiers', () {
      // Equal → equal: unmarked.
      expect(_classifyCp(game, beforeCp: 0, afterCp: 0), isNull);
      // Rough lichess table: drop of ~0.3 winning chances ≈ inaccuracy.
      expect(
        _classifyCp(game, beforeCp: 50, afterCp: -50, bestMove: 'a2a3'),
        GameMoveClassification.inaccuracy,
      );
      expect(
        _classifyCp(game, beforeCp: 100, afterCp: -150, bestMove: 'a2a3'),
        anyOf(
          GameMoveClassification.mistake,
          GameMoveClassification.blunder,
          GameMoveClassification.inaccuracy,
        ),
      );
      expect(
        _classifyCp(game, beforeCp: 200, afterCp: -400, bestMove: 'a2a3'),
        anyOf(
          GameMoveClassification.blunder,
          GameMoveClassification.mistake,
        ),
      );
    });

    test('engine-best played move is not marked as an error', () {
      // hasVariation gate: when PV1 is the played move, no lichess judgment.
      expect(
        _classifyCp(game, beforeCp: 0, afterCp: -300, bestMove: 'e2e4'),
        isNot(GameMoveClassification.blunder),
      );
    });

    test('only-good-move heuristic produces Top move (Great path)', () {
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
        // Mobile: Great path returns bestMove ('Top move').
        GameMoveClassification.bestMove,
      );
    });

    test('throwing a clear win produces Missed Win', () {
      expect(
        _classifyCp(
          game,
          beforeCp: 400,
          afterCp: 0,
          bestMove: 'a2a3',
          beforeWin: 80,
          afterWin: 50,
        ),
        anyOf(
          GameMoveClassification.missedWin,
          GameMoveClassification.blunder,
          GameMoveClassification.mistake,
        ),
      );
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

GameMoveClassification? _classifyCp(
  ChessGame game, {
  required int beforeCp,
  required int afterCp,
  String bestMove = 'a2a3',
  bool alternatives = true,
  double? beforeWin,
  double? afterWin,
}) {
  final lines = [
    _line(cp: beforeCp, moves: [bestMove]),
    if (alternatives) _line(cp: beforeCp - 50, moves: const ['h2h3']),
  ];
  final beforeLine = lines.first;
  final afterLine = _line(cp: afterCp);
  final before = beforeWin ?? gameReportWinPercentage(beforeLine);
  final after = afterWin ?? gameReportWinPercentage(afterLine);
  return classifyGameReportMove(
    index: 0,
    game: game,
    positions: [
      GameReportPosition(fen: game.startingFen, lines: lines),
      GameReportPosition(fen: game.mainline.first.fen, lines: [afterLine]),
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
