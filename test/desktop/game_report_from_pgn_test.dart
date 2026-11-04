import 'dart:io';

import 'package:chessever/desktop/services/board_report_output.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/game_report_allowance.dart';
import 'package:chessever/desktop/services/engine/game_report_from_pgn.dart';
import 'package:chessever/desktop/services/engine/game_report_request_coordinator.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart';
import 'package:chessever/screens/chessboard/utils/chessever_report_stamp.dart';
import 'package:chessever/screens/chessboard/utils/pgn_external_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real broadcast game exactly as the analysis service's hourly prewarm left
/// it in `games.pgn` before reports were stamped: every ply scored, ChessEver
/// classes as `$240`–`$247`, and nothing proving who wrote them. This is the
/// game that sat on "Refining move 2 of 99" in the browser.
ChessGame _unstampedPrewarm() => ChessGame.fromPgn(
  'chess.com:188037485477',
  File(
    'test/fixtures/prewarmed_report_nakamura_bok_2026.pgn',
  ).readAsStringSync(),
);

/// The moves alone: what the report writer receives once foreign annotations
/// are stripped (the server's `stripForeignAnnotations`).
ChessGame _bare(ChessGame game) => game.copyWith(
  mainline: <ChessMove>[
    for (final move in game.mainline)
      ChessMove(
        num: move.num,
        fen: move.fen,
        san: move.san,
        uci: move.uci,
        turn: move.turn,
        clockTime: move.clockTime,
      ),
  ],
);

/// The same game as the report writer now produces it: the report merged onto
/// the bare moves by [mergeGameReportAnnotationsForExport], serialised and
/// parsed back, which is what every client receives.
ChessGame _writtenByOurReport() {
  final source = _unstampedPrewarm();
  // The verdicts and scores the prewarm computed, taken as a report.
  final report = gameAnalysisReportFromPgn(withChesseverReportStamp(source))!;
  final pgn = exportGameToPgn(
    mergeGameReportAnnotationsForExport(_bare(source), report.moves),
  );
  return ChessGame.fromPgn(source.gameId, pgn);
}

ChessGame _reparse(ChessGame game) =>
    ChessGame.fromPgn(game.gameId, exportGameToPgn(game));

ChessGame _withMove(ChessGame game, int index, ChessMove move) => game.copyWith(
  mainline: <ChessMove>[
    for (var i = 0; i < game.mainline.length; i++)
      i == index ? move : game.mainline[i],
  ],
);

void main() {
  group('gameAnalysisReportFromPgn restores only our own analysis', () {
    test('a report our writer produced is restored exactly', () {
      final game = _writtenByOurReport();
      expect(
        game.metadata[kChesseverReportStampTag],
        startsWith('$kChesseverReportStampVersion '),
      );
      expect(carriesVerifiedChesseverReport(game), isTrue);

      final report = gameAnalysisReportFromPgn(
        game,
        whiteRating: 2800,
        blackRating: 2612,
      );
      expect(report, isNotNull);
      report!;
      expect(report.fingerprint, gameReportFingerprint(game));
      expect(report.moves, hasLength(99));
      expect(report.positions, hasLength(100));

      int count(GameMoveClassification c) =>
          report.moves.where((move) => move.classification == c).length;
      expect(count(GameMoveClassification.bookMove), 14);
      expect(count(GameMoveClassification.goodMove), 6);
      expect(count(GameMoveClassification.bestMove), 2);
      expect(count(GameMoveClassification.inaccuracy), 6);
      expect(count(GameMoveClassification.mistake), 3);
      expect(
        report.moves.where((m) => m.classification == null),
        hasLength(68),
      );

      // 11. d4 $6 $244 { [%eval -0.50] }
      final d4 = report.moves[20];
      expect(d4.san, 'd4');
      expect(d4.classification, GameMoveClassification.inaccuracy);
      expect(d4.evaluation.centipawns, -50);
      expect(report.moves[14].san, 'h3');
      expect(report.moves[14].classification, isNull);

      // The start position borrows the first played score.
      expect(report.positions.first.bestLine.centipawns, 32);
      expect(report.whiteAccuracy, inExclusiveRange(0, 100));
      expect(report.blackAccuracy, inExclusiveRange(0, 100));
      expect(report.whiteAccuracy, greaterThan(report.blackAccuracy));
      expect(report.whiteEstimatedRating, isNotNull);
      expect(report.blackEstimatedRating, isNotNull);
      expect(
        report.generatedAt,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    });

    test('an unstamped PGN is never read as our report', () {
      // The classes and scores look exactly like a report, but nothing says we
      // wrote them: a user, another app or another engine could have.
      expect(gameAnalysisReportFromPgn(_unstampedPrewarm()), isNull);
    });

    test('a user verdict makes it the user\'s, even after a copy', () {
      final ours = _writtenByOurReport();
      // The user marks 8. h3 as Book from the palette.
      final edited = mergeUserMainlineNags(ours, {
        14: const [247],
      });
      expect(edited.metadata.containsKey(kChesseverReportStampTag), isFalse);
      expect(gameAnalysisReportFromPgn(edited), isNull);

      // Copying out drops the private `$248` marker; the user's Book must not
      // come home looking like ours.
      final copied = ChessGame.fromPgn(
        'copy',
        toExternalCompatiblePgn(exportGameToPgn(edited)),
      );
      expect(
        copied.mainline[14].nags,
        isNot(contains(kChesseverUserQualityOverrideNag)),
      );
      expect(gameAnalysisReportFromPgn(copied), isNull);
    });

    test('a user verdict that keeps the stamp still is not ours', () {
      final ours = _writtenByOurReport();
      final move = ours.mainline[14];
      final marked = _withMove(
        ours,
        14,
        move.copyWith(
          nags: [...?move.nags, 1, kChesseverUserQualityOverrideNag],
        ),
      );
      expect(marked.metadata.containsKey(kChesseverReportStampTag), isTrue);
      expect(gameAnalysisReportFromPgn(marked), isNull);
    });

    test('an edited class, score or move breaks the stamp', () {
      final ours = _writtenByOurReport();
      final h3 = ours.mainline[14];

      final reclassified = _withMove(ours, 14, h3.copyWith(nags: const [247]));
      expect(gameAnalysisReportFromPgn(reclassified), isNull);

      final rescored = _withMove(ours, 14, h3.copyWith(eval: '1.50'));
      expect(gameAnalysisReportFromPgn(rescored), isNull);

      final declassified = _withMove(
        ours,
        0,
        ours.mainline.first.copyWith(nags: const []),
      );
      expect(gameAnalysisReportFromPgn(declassified), isNull);

      final truncated = ours.copyWith(
        mainline: ours.mainline.sublist(0, ours.mainline.length - 1),
      );
      expect(gameAnalysisReportFromPgn(truncated), isNull);
    });

    test('annotating around the report keeps it ours', () {
      final ours = _writtenByOurReport();
      final h3 = ours.mainline[14];
      // A comment and a positional symbol are not verdicts.
      final annotated = _reparse(
        _withMove(
          ours,
          14,
          h3.copyWith(
            nags: [...?h3.nags, 14],
            comments: [...?h3.comments, 'Prophylaxis.'],
          ),
        ),
      );
      expect(gameAnalysisReportFromPgn(annotated), isNotNull);
    });

    test('our report survives the copy boundary', () {
      final ours = _writtenByOurReport();
      final copied = ChessGame.fromPgn(
        'copy',
        toExternalCompatiblePgn(exportGameToPgn(ours)),
      );
      expect(gameAnalysisReportFromPgn(copied), isNotNull);
    });

    test('a stamp pasted onto another game proves nothing', () {
      final ours = _writtenByOurReport();
      final other = ChessGame.fromPgn(
        'other',
        '[Result "1-0"]\n'
            '[$kChesseverReportStampTag "${ours.metadata[kChesseverReportStampTag]}"]\n\n'
            '1. e4 \$247 { [%eval 0.30] } 1... e5 \$247 { [%eval 0.25] } 1-0',
      );
      expect(gameAnalysisReportFromPgn(other), isNull);
    });

    test('the writer only stamps a report that covered every move', () {
      final source = _unstampedPrewarm();
      final report =
          gameAnalysisReportFromPgn(withChesseverReportStamp(source))!;

      final partial = mergeGameReportAnnotationsForExport(
        _bare(source),
        report.moves.sublist(0, report.moves.length - 1),
      );
      expect(partial.metadata.containsKey(kChesseverReportStampTag), isFalse);

      final unscored = mergeGameReportAnnotationsForExport(_bare(source), [
        for (final move in report.moves)
          move.ply == 15
              ? GameReportMove(
                ply: move.ply,
                san: move.san,
                uci: move.uci,
                isWhite: move.isWhite,
                classification: move.classification,
                evaluation: const GameReportLine(moves: [], depth: 0),
              )
              : move,
      ]);
      expect(unscored.metadata.containsKey(kChesseverReportStampTag), isFalse);
    });

    test('the stamp payload is the cross-app contract', () {
      // Pinned: mobile and the analysis service carry byte-identical copies of
      // the stamp, so this exact value must come out of all three.
      final game = ChessGame.fromPgn(
        'vector',
        '[Result "*"]\n\n'
            '1. e4 \$247 { [%eval 0.30] } 1... e5 \$247 { [%eval 0.25] } '
            '2. Nf3 { [%eval 0.20] } 2... Nc6 \$6 \$244 { [%eval #-3] } *',
      );
      expect(
        chesseverReportStampPayload(game),
        'chessever-report-stamp v1\n'
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq\n'
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq\t247\t0.30\n'
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq\t247\t0.25\n'
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq\t-\t0.20\n'
        'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq\t244\t#-3\n',
      );
      expect(chesseverReportStampFor(game), kStampTestVector);
    });
  });

  group('parseSavedReportEvaluation', () {
    test('reads what a report writes and nothing else', () {
      expect(parseSavedReportEvaluation('0.32')?.centipawns, 32);
      expect(parseSavedReportEvaluation('-1.05')?.centipawns, -105);
      expect(parseSavedReportEvaluation('+2')?.centipawns, 200);
      expect(parseSavedReportEvaluation('#3')?.mate, 3);
      expect(parseSavedReportEvaluation('#-2')?.mate, -2);
      expect(parseSavedReportEvaluation('0.32,14')?.depth, 14);
      expect(parseSavedReportEvaluation(null), isNull);
      expect(parseSavedReportEvaluation('abc'), isNull);
      expect(parseSavedReportEvaluation('0.3,1,2'), isNull);
    });
  });

  group('request coordinator adopts our PGN report instead of analysing', () {
    Future<
      ({
        GameReportRequestResult result,
        int runs,
        GameAnalysisReportController controller,
      })
    >
    request({
      required bool premium,
      required ChessGame game,
      GameReportAllowanceStore? allowance,
    }) async {
      var runs = 0;
      final controller = GameAnalysisReportController(
        remoteRunner: (
          game, {
          whiteRating,
          blackRating,
          required onProgress,
          required isCancelled,
        }) async {
          runs++;
          throw StateError('remote unavailable in this test');
        },
      );
      addTearDown(controller.dispose);
      final result = await GameReportRequestCoordinator(
        accountId: () => 'account-1',
        isPremium: () => premium,
        store: GameAnalysisReportStore.memory(),
        allowanceStore: allowance ?? GameReportAllowanceStore.memory(),
      ).request(
        controller: controller,
        game: game,
        gameFinished: true,
        whiteRating: 2800,
        blackRating: 2612,
      );
      return (result: result, runs: runs, controller: controller);
    }

    test('premium sees the report at once, with no engine or server', () async {
      final out = await request(premium: true, game: _writtenByOurReport());

      expect(out.result.outcome, GameReportRequestOutcome.restored);
      expect(out.runs, 0);
      expect(out.controller.state.status, GameReportStatus.completed);
      expect(out.controller.state.report?.moves, hasLength(99));
    });

    test('an unused free report is spent on it, like any restore', () async {
      final allowance = GameReportAllowanceStore.memory();
      final out = await request(
        premium: false,
        game: _writtenByOurReport(),
        allowance: allowance,
      );

      expect(out.result.outcome, GameReportRequestOutcome.restored);
      expect(out.result.reason, 'free_success');
      expect(out.runs, 0);
      expect(await allowance.hasLifetimeSuccess('account-1'), isTrue);
    });

    test('reading a PGN report never bypasses a spent allowance', () async {
      final allowance = GameReportAllowanceStore.memory();
      await allowance.markFreeSuccess('account-1', 'another-game');
      final out = await request(
        premium: false,
        game: _writtenByOurReport(),
        allowance: allowance,
      );

      expect(out.result.outcome, GameReportRequestOutcome.quotaExceeded);
      expect(out.runs, 0);
      expect(out.controller.state.status, isNot(GameReportStatus.completed));
    });

    test('a user-annotated PGN goes to analysis, not to restore', () async {
      final userMarked = mergeUserMainlineNags(_writtenByOurReport(), {
        14: const [247],
      });
      final controller = GameAnalysisReportController(
        remoteRunner: (
          game, {
          whiteRating,
          blackRating,
          required onProgress,
          required isCancelled,
        }) async {
          return gameAnalysisReportFromPgn(_writtenByOurReport())!;
        },
      );
      addTearDown(controller.dispose);
      final result = await GameReportRequestCoordinator(
        accountId: () => 'account-1',
        isPremium: () => true,
        store: GameAnalysisReportStore.memory(),
        allowanceStore: GameReportAllowanceStore.memory(),
      ).request(controller: controller, game: userMarked, gameFinished: true);

      // Analysed (here by the fake server), never adopted from the PGN.
      expect(result.outcome, GameReportRequestOutcome.generated);
    });
  });
}

/// Pinned stamp for the payload vector above.
const kStampTestVector =
    'v1 e5f1e86020d08b05e01b6799e167800947e9b28c2337bbf53c197e99b7260c91';
