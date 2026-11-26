
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/play/play_live_move_classifier.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// A search that reads [whiteCp] for every line of [fen], from moves that are
/// legal there, the way a real engine's batch looks to the report.
GameReportPosition _fakeSearch(
  String fen, {
  required int depth,
  required int multiPv,
  required int whiteCp,
}) {
  final position = Chess.fromSetup(Setup.parseFen(fen));
  final legal = <String>[
    for (final entry in position.legalMoves.entries)
      for (final to in entry.value.squares)
        NormalMove(from: entry.key, to: to).uci,
  ]..sort();
  return GameReportPosition(
    fen: fen,
    lines: [
      for (var i = 0; i < multiPv && i < legal.length; i++)
        GameReportLine(
          moves: [legal[i]],
          depth: depth,
          // The best line keeps the reading; each next one is a little worse
          // for the side to move.
          centipawns:
              whiteCp + (position.turn == Side.white ? -i * 15 : i * 15),
        ),
    ],
    search: GameReportSearchEvidence(
      engineId: 'fake',
      searchId: '$fen:$depth',
      complete: true,
    ),
  );
}

Future<PlayLiveMoveJudgements> _settle(
  PlayLiveMoveClassifier classifier,
) async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return classifier.state;
}

void main() {
  group('PlayLiveUciBatches', () {
    test('keeps the deepest complete batch, scores from White', () {
      final batches =
          PlayLiveUciBatches(multiPv: 2)
            ..add(
              'info depth 13 seldepth 18 multipv 1 score cp 40 nodes 1 pv e7e5 g1f3',
            )
            ..add(
              'info depth 13 seldepth 18 multipv 2 score cp 30 nodes 1 pv c7c5',
            )
            ..add(
              'info depth 14 seldepth 19 multipv 1 score cp 35 nodes 1 pv e7e5',
            )
            // Depth 14 never finished its second line: depth 13 is the batch.
            ..add(
              'info depth 14 seldepth 19 multipv 1 score cp 50 lowerbound pv d7d5',
            );
      final lines = batches.deepestBatch(whiteToMove: false);
      expect(lines.map((line) => line.depth), [13, 13]);
      expect(lines.map((line) => line.moves.first), ['e7e5', 'c7c5']);
      // Black to move: +40 for Black is -40 for White.
      expect(lines.map((line) => line.centipawns), [-40, -30]);
    });

    test('reads mate scores and a single legal move', () {
      final batches = PlayLiveUciBatches(multiPv: 3)
        ..add('info depth 20 multipv 1 score mate 2 pv d1h5 g7g6 h5e8');
      final lines = batches.deepestBatch(whiteToMove: true);
      expect(lines, hasLength(1));
      expect(lines.single.mate, 2);
      expect(lines.single.centipawns, isNull);
    });
  });

  group('PlayLiveMoveClassifier', () {
    test('judges each move as it lands, with the report rules', () async {
      // 1.e4 f6?? reads as winning for White once Black has played it.
      final cpAfter = <int, int>{0: 20, 1: 30, 2: 900};
      final searched = <String>[];
      late ChessGame game;
      final classifier = PlayLiveMoveClassifier(
        openEvaluator:
            () async => (fen, {required depth, required multiPv}) async {
              searched.add(fen);
              final ply =
                  fen == game.startingFen
                      ? 0
                      : game.mainline.indexWhere((m) => m.fen == fen) + 1;
              return _fakeSearch(
                fen,
                depth: depth,
                multiPv: multiPv,
                whiteCp: cpAfter[ply]!,
              );
            },
        bookLookup: (fen, uci, path) async => path.isEmpty ? 5000 : 0,
      );
      addTearDown(classifier.dispose);

      game = playLiveClassifierGame(kInitialFEN, const ['e2e4']);
      classifier.sync(game);
      var judged = await _settle(classifier);
      expect(judged.judgedMoves, 1);
      expect(judged.classes[0], GameMoveClassification.bookMove);

      game = playLiveClassifierGame(kInitialFEN, const ['e2e4', 'f7f6']);
      classifier.sync(game);
      judged = await _settle(classifier);
      expect(judged.judgedMoves, 2);
      expect(judged.classes[1], GameMoveClassification.blunder);
      // Each position is searched once, however often the game grows.
      expect(searched.toSet().length, searched.length);
    });

    test('starts over when the game is not a continuation', () async {
      final classifier = PlayLiveMoveClassifier(
        openEvaluator:
            () async =>
                (fen, {required depth, required multiPv}) async => _fakeSearch(
                  fen,
                  depth: depth,
                  multiPv: multiPv,
                  whiteCp: 20,
                ),
      );
      addTearDown(classifier.dispose);
      classifier.sync(playLiveClassifierGame(kInitialFEN, const ['e2e4']));
      expect((await _settle(classifier)).judgedMoves, 1);
      classifier.sync(playLiveClassifierGame(kInitialFEN, const ['d2d4']));
      final judged = await _settle(classifier);
      expect(judged.judgedMoves, 1);
    });

    test('marks only theory when no engine can start', () async {
      final classifier = PlayLiveMoveClassifier(
        openEvaluator: () async => null,
        bookLookup: (fen, uci, path) async => 400,
      );
      addTearDown(classifier.dispose);
      classifier.sync(
        playLiveClassifierGame(kInitialFEN, const ['e2e4', 'e7e5']),
      );
      final judged = await _settle(classifier);
      expect(judged.engineAvailable, isFalse);
      expect(judged.judgedMoves, 2);
      expect(
        judged.classes.values,
        everyElement(GameMoveClassification.bookMove),
      );
    });
  });
}
