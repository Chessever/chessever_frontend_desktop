import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_report_consistency_test.dart' as fixture;

void main() {
  test(
    'local desktop/browser controller reconciles final snapshots, not pass2 selection',
    () async {
      final game = fixture.rc7Game();
      final fens = gameReportFens(game);
      final calls = <({String fen, int depth, int multiPv})>[];
      final controller = GameAnalysisReportController(
        evaluator: (
          fen, {
          required depth,
          required multiPv,
          required ownerId,
          onProgress,
        }) async {
          calls.add((fen: fen, depth: depth, multiPv: multiPv));
          final i = fens.indexOf(fen);
          final pvs =
              depth >= 18
                  ? i == 0
                      ? [
                        Pv(moves: 'd2e3', cp: 31),
                        Pv(moves: 'b3b4', cp: 2),
                        Pv(moves: 'f3g1', cp: 0),
                      ]
                      : i == 1
                      ? [
                        Pv(moves: 'h5h3 g2h1 h3f1 f3g1 f6e4', cp: -729),
                        Pv(moves: 'f6e4', cp: 0),
                        Pv(moves: 'g5g4', cp: 27),
                      ]
                      : [Pv(moves: 'g2h1 h3f1 f3g1 f6e4', cp: -729)]
                  : [
                    Pv(
                      moves:
                          i == 0
                              ? 'c1c7 g5g4'
                              : i == 1
                              ? 'h5h3 g2h1 h3f1 f3g1 f6e4'
                              : i == 2
                              ? 'g2h1 h3f1 f3g1 f6e4'
                              : 'h3f1',
                      cp: i == 0 ? 70 : -736,
                    ),
                  ];
          return EnhancedCloudEval(
            fen: fen,
            knodes: 20,
            depth: depth,
            pvs: pvs,
            requestedMultiPv: multiPv,
          );
        },
      );
      addTearDown(controller.dispose);
      await controller.analyze(game);
      expect(controller.state.status, GameReportStatus.completed);
      final report = controller.state.report!;
      expect(report.moves[0].classification, GameMoveClassification.blunder);
      expect(report.moves[0].bestAlternative, 'd2e3');
      expect(report.moves[1].classification, GameMoveClassification.brilliant);
      expect(report.positions.first.bestLine.depth, 18);
      expect(
        calls
            .take(4)
            .every(
              (c) =>
                  c.multiPv == 1 &&
                  c.depth == GameAnalysisReportController.reportDepth,
            ),
        true,
      );
      // The Rc7 candidate is refined despite its collapsing child, because the
      // frozen primary-pass selector still includes played-is-best.
      expect(
        calls.any(
          (c) =>
              c.fen == fens.first &&
              c.multiPv == 3 &&
              c.depth == GameAnalysisReportController.reportDepth,
        ),
        true,
      );
      expect(calls.where((c) => c.depth >= 18).length, lessThanOrEqualTo(6));
    },
  );

  test(
    'node exhaustion leaves uncertainty and no unsupported praise',
    () async {
      final game = fixture.rc7Game();
      final fens = gameReportFens(game);
      var confirmations = 0;
      final controller = GameAnalysisReportController(
        evaluator: (
          fen, {
          required depth,
          required multiPv,
          required ownerId,
          onProgress,
        }) async {
          final i = fens.indexOf(fen);
          if (depth >= 18) {
            confirmations++;
            onProgress?.call(depth, 7000);
          }
          return EnhancedCloudEval(
            fen: fen,
            knodes: depth >= 18 ? 7000 : 10,
            depth: depth,
            pvs: [
              Pv(
                moves:
                    i == 0
                        ? 'c1c7'
                        : i == 1
                        ? 'h5h3 g2h1 h3f1 f3g1 f6e4'
                        : i == 2
                        ? 'g2h1 h3f1 f3g1 f6e4'
                        : 'h3f1',
                cp: i == 0 ? 70 : -736,
              ),
            ],
            requestedMultiPv: multiPv,
          );
        },
      );
      addTearDown(controller.dispose);
      await controller.analyze(game);
      expect(controller.state.status, GameReportStatus.completed);
      expect(confirmations, 1);
      expect(controller.state.report!.positions.first.uncertainty, isNotNull);
      expect(controller.state.report!.moves.first.classification, isNull);
    },
  );

  final binary = Platform.environment['NATIVE_REPORT_STOCKFISH'];
  test(
    'real SF18 bounded two-root replay repairs actual captured Rc7',
    () async {
      final game = fixture.rc7Game();
      final traces = <Map<String, dynamic>>[];
      final result = await confirmGameReportConsistency(
        game: game,
        positions: fixture.shallow(game),
        isCancelled: () => false,
        budget: const GameReportConfirmationBudget(maxConflicts: 2),
        evaluate: (r) => freshSearch(binary!, r, traces),
      );
      final report = buildGameAnalysisReport(
        game: game,
        fingerprint: gameReportFingerprint(game),
        positions: result,
      );
      final receipt = <String, dynamic>{
        'traces': traces,
        'classification': report.moves.first.classification?.name,
        'criticalReplyClassification': report.moves[1].classification?.name,
        'criticalReason': nativeCriticalPunishmentReason(
          index: 1,
          game: game,
          positions: result,
          previous: report.moves.first.classification,
        ),
        'alternative': report.moves.first.bestAlternative,
        'whiteAccuracy': report.whiteAccuracy,
        'uncertainty': result.first.uncertainty,
      };
      final output = Platform.environment['NATIVE_REPORT_STOCKFISH_RECEIPT'];
      if (output != null) {
        File(output).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(receipt),
        );
      }
      expect(report.moves.first.classification, GameMoveClassification.blunder);
      expect(report.moves[1].classification, GameMoveClassification.brilliant);
      expect(report.moves.first.bestAlternative, 'd2e3');
      expect(result.first.uncertainty, isNull);
      expect(
        traces.every((t) => (t['engine'] as String).contains('Stockfish 18')),
        true,
      );
    },
    skip:
        binary == null
            ? 'Set NATIVE_REPORT_STOCKFISH to an actual SF18 executable'
            : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<GameReportPosition> freshSearch(
  String binary,
  GameReportConfirmationRequest request,
  List<Map<String, dynamic>> traces,
) async {
  final process = await Process.start(binary, const []);
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final raw = <String>[];
  var engine = '';
  final batches = <int, Map<int, GameReportLine>>{};
  final sign = request.fen.split(' ')[1] == 'w' ? 1 : -1;
  Future<void> until(String token) async {
    while (await lines.moveNext()) {
      final s = lines.current;
      raw.add(s);
      if (s.startsWith('id name ')) {
        engine = s.substring(8);
      }
      if (s.startsWith('info depth ') &&
          s.contains(' pv ') &&
          !s.contains('bound')) {
        final depth = int.parse(RegExp(r'\bdepth (\d+)').firstMatch(s)![1]!);
        final rank =
            int.tryParse(RegExp(r'\bmultipv (\d+)').firstMatch(s)?[1] ?? '') ??
            1;
        final cp = int.tryParse(
          RegExp(r'\bscore cp (-?\d+)').firstMatch(s)?[1] ?? '',
        );
        final mate = int.tryParse(
          RegExp(r'\bscore mate (-?\d+)').firstMatch(s)?[1] ?? '',
        );
        batches.putIfAbsent(depth, () => {})[rank] = GameReportLine(
          moves: s.split(' pv ').last.split(' '),
          depth: depth,
          centipawns: cp == null ? null : cp * sign,
          mate: mate == null ? null : mate * sign,
        );
      }
      if (s.startsWith(token)) return;
    }
    throw StateError('Stockfish closed before $token');
  }

  try {
    process.stdin.writeln('uci');
    await until('uciok').timeout(const Duration(seconds: 3));
    process.stdin.writeln('setoption name Threads value 1');
    process.stdin.writeln('setoption name Hash value 16');
    process.stdin.writeln('setoption name MultiPV value ${request.multiPv}');
    process.stdin.writeln('ucinewgame');
    process.stdin.writeln('isready');
    await until('readyok').timeout(const Duration(seconds: 3));
    process.stdin.writeln('position fen ${request.fen}');
    final command =
        'go depth ${request.depth} nodes ${request.maxNodes} movetime ${request.maxTime.inMilliseconds}';
    process.stdin.writeln(command);
    await until(
      'bestmove',
    ).timeout(request.maxTime + const Duration(seconds: 1));
    final complete =
        batches.keys
            .where((d) => batches[d]!.length == request.multiPv)
            .toList()
          ..sort();
    if (complete.isEmpty) throw StateError('No complete effective-depth batch');
    final reached = complete.last;
    final selected = [
      for (var rank = 1; rank <= request.multiPv; rank++)
        batches[reached]![rank]!,
    ];
    traces.add({
      'fen': request.fen,
      'engine': engine,
      'command': command,
      'depth': reached,
      'lines': [
        for (final l in selected)
          {
            'moves': l.moves,
            'centipawns': l.centipawns,
            'mate': l.mate,
            'depth': l.depth,
          },
      ],
      'raw': raw,
    });
    return GameReportPosition(
      fen: request.fen,
      lines: selected,
      search: GameReportSearchEvidence(
        engineId: engine,
        searchId: 'real-${traces.length}',
        complete: true,
      ),
    );
  } finally {
    process.stdin.writeln('quit');
    await process.stdin.flush();
    await lines.cancel();
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 2));
  }
}
