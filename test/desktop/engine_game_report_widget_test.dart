import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  final game = ChessGame.fromPgn(
    'widget-report',
    '[White "Ada"]\n[Black "Grace"]\n[ECO "C20"]\n\n1. e4 e5 *',
  );

  testWidgets('EnginePanel defaults to Moves and exposes the Report tab', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SizedBox(
            width: 520,
            height: 360,
            child: EnginePanel(
              fen: '',
              sideToMove: 'w',
              game: game,
              headers: const {'White': 'Ada', 'Black': 'Grace'},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Moves'), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('Engine analysis off'), findsOneWidget);

    await tester.tap(find.text('Report'));
    await tester.pump();
    expect(find.text('Analyze Game'), findsOneWidget);
    expect(find.textContaining('three candidate lines'), findsOneWidget);
  });

  testWidgets(
    'report progress exposes cancellation and blocks partial output',
    (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 520,
            height: 360,
            child: GameReportView(
              state: const GameReportState(
                status: GameReportStatus.running,
                progress: 0.5,
                completedPositions: 2,
                totalPositions: 4,
                message: 'Analyzing position 2 of 4',
              ),
              game: game,
              headers: const {'White': 'Ada', 'Black': 'Grace'},
              activePly: 0,
              onAnalyze: () async {},
              onCancel: () async => cancelled = true,
              onJumpToPly: null,
            ),
          ),
        ),
      );

      expect(find.text('50% · 2/4'), findsOneWidget);
      expect(find.text('Game report'), findsNothing);
      await tester.tap(find.text('Cancel'));
      expect(cancelled, isTrue);
    },
  );

  testWidgets('completed report rows navigate to their mainline ply', (
    tester,
  ) async {
    int? jumpedPly;
    final report = GameAnalysisReport(
      fingerprint: gameReportFingerprint(game),
      positions: [
        _position(game.startingFen, 0),
        _position(game.mainline[0].fen, 30),
        _position(game.mainline[1].fen, 5),
      ],
      moves: [
        GameReportMove(
          ply: 1,
          san: 'e4',
          uci: 'e2e4',
          isWhite: true,
          classification: GameMoveClassification.best,
          evaluation: _line(30),
          bestAlternative: 'd2d4',
        ),
        GameReportMove(
          ply: 2,
          san: 'e5',
          uci: 'e7e5',
          isWhite: false,
          classification: GameMoveClassification.excellent,
          evaluation: _line(5),
        ),
      ],
      whiteAccuracy: 98.4,
      blackAccuracy: 94.2,
      whiteEstimatedRating: 2050,
      blackEstimatedRating: 1910,
      generatedAt: DateTime(2026),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 520,
          height: 700,
          child: GameReportView(
            state: GameReportState(
              status: GameReportStatus.completed,
              progress: 1,
              report: report,
            ),
            game: game,
            headers: const {'White': 'Ada', 'Black': 'Grace', 'ECO': 'C20'},
            activePly: 1,
            onAnalyze: () async {},
            onCancel: () async {},
            onJumpToPly: (ply) => jumpedPly = ply,
          ),
        ),
      ),
    );

    expect(find.text('98.4%'), findsOneWidget);
    expect(find.text('2050'), findsOneWidget);
    expect(find.text('C20'), findsOneWidget);
    await tester.tap(find.text('1.e4'));
    expect(jumpedPly, 1);
  });
}

GameReportPosition _position(String fen, int cp) =>
    GameReportPosition(fen: fen, lines: [_line(cp)]);

GameReportLine _line(int cp) =>
    GameReportLine(moves: const ['a2a3'], depth: 16, centipawns: cp);
