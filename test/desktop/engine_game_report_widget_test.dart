import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  final game = ChessGame.fromPgn(
    'widget-report',
    '[White "Ada"]\n[Black "Grace"]\n[ECO "C20"]\n\n1. e4 e5 *',
  );

  testWidgets('EnginePanel switches to the externally selected Report view', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineSettingsProviderNew.overrideWith(_EngineAnalysisOnNotifier.new),
        ],
        child: MaterialApp(
          home: SizedBox(
            width: 520,
            height: 360,
            child: EnginePanel(
              fen: '',
              sideToMove: 'w',
              game: game,
              headers: const {'White': 'Ada', 'Black': 'Grace'},
              reportVisible: true,
              autoAnalysisAllowed: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Analyze Game'), findsOneWidget);
    expect(find.textContaining('three candidate lines'), findsOneWidget);

    final reportSplit = tester.widget<ResizableSplitView>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ResizableSplitView &&
            widget.storageKey == desktopEngineReportSplitStorageKey,
      ),
    );
    expect(reportSplit.axis, Axis.vertical);
    expect(reportSplit.gutterThickness, desktopEngineReportGutterThickness);
    expect(reportSplit.children.first.minSize, 80);
    expect(reportSplit.children.last.minSize, 140);
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

      // The progress bar eases to its target, so let the animation finish
      // before asserting the settled percentage.
      await tester.pumpAndSettle();
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
          classification: GameMoveClassification.bestMove,
          evaluation: _line(30),
          bestAlternative: 'd2d4',
        ),
        GameReportMove(
          ply: 2,
          san: 'e5',
          uci: 'e7e5',
          isWhite: false,
          classification: GameMoveClassification.goodMove,
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
    expect(find.text('Brilliant'), findsOneWidget);
    expect(find.text('Best'), findsWidgets);
    expect(find.text('Great'), findsOneWidget);
    expect(find.text('Missed Win'), findsOneWidget);
    expect(find.text('Forced'), findsNothing);
    expect(find.text('Excellent'), findsNothing);
    expect(find.text('Okay'), findsNothing);
    expect(find.byType(SvgPicture), findsWidgets);
    expect(find.text('1.e4'), findsNothing);
    expect(find.text('Moves'), findsNothing);
    await tester.tapAt(tester.getCenter(find.byType(CustomPaint).first));
    expect(jumpedPly, isNotNull);
  });
}

class _EngineAnalysisOnNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings(showEngineAnalysis: true);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

GameReportPosition _position(String fen, int cp) =>
    GameReportPosition(fen: fen, lines: [_line(cp)]);

GameReportLine _line(int cp) =>
    GameReportLine(moves: const ['a2a3'], depth: 16, centipawns: cp);
