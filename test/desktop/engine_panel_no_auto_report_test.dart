import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/game_report_request_coordinator.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Settings exactly as a build up to 20.32.16 left them in the local cache,
/// with automatic report generation switched on.
class _LegacyAutoReportSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    final settings = engineSettingsFromCache(<String, dynamic>{
      'showEngineGauge': true,
      'showDepthOverlay': true,
      'showPvArrows': true,
      'showEngineAnalysis': false,
      'autoGameAnalysis': true,
      'searchTimeIndex': 0,
      'principalVariationIndex': 4,
      'maxArrowsOnBoard': 2,
    });
    state = AsyncValue.data(settings);
    return settings;
  }
}

void main() {
  testWidgets(
    'a loaded finished game never starts a report on its own, even with the '
    'legacy automatic setting on',
    (tester) async {
      var engineRuns = 0;
      var claims = 0;
      final controller = GameAnalysisReportController(
        evaluator: (
          fen, {
          required depth,
          required multiPv,
          required ownerId,
          onProgress,
        }) async {
          engineRuns++;
          return EnhancedCloudEval(fen: fen, knodes: 1, depth: depth, pvs: []);
        },
      );
      addTearDown(controller.dispose);
      final coordinator = GameReportRequestCoordinator(
        claim: (_) async {
          claims++;
          throw Exception('offline');
        },
        accountId: () => 'account-1',
        store: GameAnalysisReportStore.memory(),
      );
      final game = ChessGame.fromPgn(
        'auto-report',
        '[White "Ada"]\n[Black "Grace"]\n[Result "1-0"]\n\n1. e4 e5 1-0',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            engineSettingsProviderNew.overrideWith(
              _LegacyAutoReportSettings.new,
            ),
          ],
          child: MaterialApp(
            home: SizedBox(
              width: 520,
              height: 420,
              child: EnginePanel(
                fen: '',
                sideToMove: 'w',
                game: game,
                headers: const {
                  'White': 'Ada',
                  'Black': 'Grace',
                  'Result': '1-0',
                },
                reportVisible: true,
                autoAnalysisAllowed: true,
                reportController: controller,
                reportCoordinator: coordinator,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(claims, 0);
      expect(engineRuns, 0);
      expect(controller.state.status, GameReportStatus.idle);
      expect(find.text('Analyze Game'), findsOneWidget);

      // An explicit request is the only way in. A failed claim is Retry,
      // never a purchase prompt, and starts no engine work.
      await tester.tap(find.text('Analyze Game'));
      await tester.pump();
      await tester.pump();

      expect(claims, 1);
      expect(engineRuns, 0);
      expect(find.text("Couldn't check your report allowance"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    },
  );
}
