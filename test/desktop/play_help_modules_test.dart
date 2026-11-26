import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/board_analysis_preferences.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/widgets/play_help_modules_panel.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('play help modules', () {
    test('everything starts off', () {
      const modules = PlayHelpModules();
      expect(modules.anyOn, isFalse);
      expect(modules.showsRail, isFalse);
      expect(modules.needsStockfish, isFalse);
      expect(modules.arrows, PlayHelpArrows.off);
    });

    test('the bars and marks alone keep the plain move list', () {
      const modules = PlayHelpModules(
        evalBar: true,
        tobyBar: true,
        moveMarks: true,
        arrowEvals: true,
        arrows: PlayHelpArrows.stockfish,
      );
      expect(modules.showsRail, isFalse);
      expect(modules.needsStockfish, isTrue);
    });

    test('Toby arrows need the rail, which carries his reading', () {
      const modules = PlayHelpModules(arrows: PlayHelpArrows.toby);
      expect(modules.showsRail, isTrue);
      expect(modules.needsStockfish, isFalse);
    });

    test('saved choices read back; unknown values read as off', () {
      const modules = PlayHelpModules(
        engineLines: true,
        moveMarks: true,
        arrows: PlayHelpArrows.toby,
      );
      expect(PlayHelpModules.fromJson(modules.toJson()), modules);
      expect(
        PlayHelpModules.fromJson(const {'arrows': 'laser', 'evalBar': 'yes'}),
        const PlayHelpModules(),
      );
    });
  });

  group('the engine pane inside a Play game', () {
    ProviderContainer playScope(ProviderContainer root) => ProviderContainer(
      parent: root,
      overrides: [
        boardAnalysisPreferencesProvider.overrideWith(PlayAnalysisSettings.new),
      ],
    );

    test('reads the help modules, not the Board choices', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final play = playScope(root);
      addTearDown(play.dispose);
      root
          .read(playHelpModulesProvider.notifier)
          .set(
            const PlayHelpModules(
              tobyPredictions: true,
              arrows: PlayHelpArrows.toby,
            ),
          );

      final preferences = play.read(boardAnalysisPreferencesProvider);
      expect(preferences.stockfishAnalysis, isFalse);
      expect(preferences.tobyAnalysis, isTrue);
      expect(preferences.stockfishBarChoice, isFalse);
      expect(preferences.arrowChoice, BoardAnalysisArrows.toby);
    });

    test('its switches change the modules and leave the Board alone', () {
      final root = ProviderContainer();
      addTearDown(root.dispose);
      final play = playScope(root);
      addTearDown(play.dispose);
      final boardBefore = root.read(boardAnalysisPreferencesProvider);

      final settings = play.read(boardAnalysisPreferencesProvider.notifier);
      settings.setStockfishAnalysis(true);
      settings.setArrows(BoardAnalysisArrows.stockfish);
      settings.setStockfishBar(true);

      expect(
        root.read(playHelpModulesProvider),
        const PlayHelpModules(
          engineLines: true,
          evalBar: true,
          arrows: PlayHelpArrows.stockfish,
        ),
      );
      final board = root.read(boardAnalysisPreferencesProvider);
      expect(board.stockfishAnalysis, boardBefore.stockfishAnalysis);
      expect(board.arrowChoice, boardBefore.arrowChoice);
      expect(board.stockfishBarChoice, boardBefore.stockfishBarChoice);

      // Pausing hides the engine and Toby in the rail.
      settings.setPaused(true);
      expect(root.read(playHelpModulesProvider).engineLines, isFalse);
      expect(root.read(playHelpModulesProvider).evalBar, isTrue);
    });
  });

  testWidgets('each switch turns on its own module only', (tester) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return FTheme(
              data: FThemes.zinc.dark,
              child: const MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(child: PlayHelpModulesList()),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FSwitch), findsNWidgets(7));
    await tester.tap(find.byType(FSwitch).at(4)); // Move marks
    await tester.pumpAndSettle();
    expect(
      container.read(playHelpModulesProvider),
      const PlayHelpModules(moveMarks: true),
    );

    await tester.tap(find.text('Stockfish'));
    await tester.pumpAndSettle();
    expect(
      container.read(playHelpModulesProvider),
      const PlayHelpModules(moveMarks: true, arrows: PlayHelpArrows.stockfish),
    );
    // Let the switches' tap-visual timers elapse before teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
