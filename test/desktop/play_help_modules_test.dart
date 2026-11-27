import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/board_analysis_preferences.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
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

    test('the old threat flag no longer gates Stockfish or the rail', () {
      // The threat button is always beside the clock now; Stockfish runs
      // only while it is pressed (playStockfishDemandProvider).
      const modules = PlayHelpModules(threats: true);
      expect(modules.showsRail, isFalse);
      expect(modules.needsStockfish, isFalse);
      // Nor does it count as help: nothing would be shown for it.
      expect(modules.anyOn, isFalse);
      expect(modules.chosenModules, isEmpty);
      expect(modules.copyWith(evalBar: true).anyOn, isTrue);
    });

    test('saved choices read back; unknown values read as off', () {
      const modules = PlayHelpModules(
        engineLines: true,
        moveMarks: true,
        threats: true,
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
        // Each row shows its help key; skip the database read.
        overrides: [
          keyboardShortcutsProvider.overrideWith(_DefaultShortcuts.new),
        ],
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

    // The help keys make the list taller than the test window.
    await tester.ensureVisible(find.text('Stockfish'));
    await tester.pumpAndSettle();
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

  testWidgets('a help key is recorded in place, and asks before taking '
      'another action\'s key', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyboardShortcutsProvider.overrideWith(_DefaultShortcuts.new),
        ],
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
    BoardShortcutMap map() => container.read(keyboardShortcutsProvider).value!;
    String label(LogicalKeyboardKey key, {bool shift = false}) =>
        KeyChord(keyId: key.keyId, shift: shift).label;

    // The engine lines row shows its default key; click it to record.
    final cap = find.text(label(LogicalKeyboardKey.keyL, shift: true));
    expect(cap, findsOneWidget);
    await tester.tap(cap);
    await tester.pump();
    expect(find.text('Press a key'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(map().chordsFor(BoardActionKey.playHelpEngineLines), [
      KeyChord(keyId: LogicalKeyboardKey.keyP.keyId),
    ]);
    expect(find.text('Press a key'), findsNothing);

    // F flips the Board, which never acts in Play: it is no conflict, and
    // the Board keeps it.
    await tester.tap(find.text('P'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(map().chordsFor(BoardActionKey.playHelpEngineLines), [
      KeyChord(keyId: LogicalKeyboardKey.keyF.keyId),
    ]);
    expect(map().chordsFor(BoardActionKey.flipBoard), [
      KeyChord(keyId: LogicalKeyboardKey.keyF.keyId),
    ]);

    // H is all help's: the recorder names it and waits for Replace.
    await tester.tap(find.text('F'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(find.text('H is used by Play help: all.'), findsOneWidget);
    expect(
      map().chordsFor(BoardActionKey.playHelpEngineLines).single.keyId,
      LogicalKeyboardKey.keyF.keyId,
    );
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(map().chordsFor(BoardActionKey.playHelpEngineLines), [
      KeyChord(keyId: LogicalKeyboardKey.keyH.keyId),
    ]);
    expect(map().chordsFor(BoardActionKey.playHelpAll), isEmpty);

    // Search, Play's move keys and the threat key cannot be taken: the
    // binding stays, and recording goes on with a note.
    await tester.tap(find.text('H'));
    await tester.pump();
    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
    ]) {
      for (final shift in [false, true]) {
        await tester.sendKeyDownEvent(modifier);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        expect(find.textContaining('opens search.'), findsOneWidget);
        expect(map().chordsFor(BoardActionKey.playHelpEngineLines), [
          KeyChord(keyId: LogicalKeyboardKey.keyH.keyId),
        ]);
      }
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.textContaining('steps through moves in Play.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(find.textContaining('shows the threat in Play.'), findsOneWidget);
    expect(map().chordsFor(BoardActionKey.prevMove), [
      KeyChord(keyId: LogicalKeyboardKey.arrowLeft.keyId),
    ]);
    expect(map().chordsFor(BoardActionKey.showThreat), [
      KeyChord(keyId: LogicalKeyboardKey.keyX.keyId),
    ]);
    expect(map().chordsFor(BoardActionKey.playHelpEngineLines), [
      KeyChord(keyId: LogicalKeyboardKey.keyH.keyId),
    ]);
    // Esc leaves it as it was.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Press a key'), findsNothing);

    // The keyboard reaches the keycap too: focus it and press Enter.
    final binding = find.ancestor(
      of: find.text('H'),
      matching: find.byType(PlayHelpKeyBinding),
    );
    final focus = tester
        .widgetList<Focus>(
          find.descendant(of: binding, matching: find.byType(Focus)),
        )
        .firstWhere((f) => f.focusNode?.debugLabel == 'Play help key recorder');
    focus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('Press a key'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(map().chordsFor(BoardActionKey.playHelpEngineLines), [
      KeyChord(keyId: LogicalKeyboardKey.keyF.keyId),
    ]);

    // Backspace clears it.
    await tester.tap(find.text('F'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(map().chordsFor(BoardActionKey.playHelpEngineLines), isEmpty);
    // This row and all help's, whose H was taken above.
    expect(find.text('Set key'), findsNWidgets(2));

    // Saving writes to a database the test never opens: let it time out.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}

class _DefaultShortcuts extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}
