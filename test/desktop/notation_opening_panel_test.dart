import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:dartchess/dartchess.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _initialFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

BoardShortcutMap? _shortcutMapOverride;

void main() {
  tearDown(() => _shortcutMapOverride = null);

  test(
    'right rail primary arrow chords map to macOS and Windows modifiers',
    () {
      expect(
        debugIsRightRailNextTabChord(
          key: LogicalKeyboardKey.arrowRight,
          isMac: true,
          meta: true,
        ),
        isTrue,
      );
      expect(
        debugIsRightRailPreviousTabChord(
          key: LogicalKeyboardKey.arrowLeft,
          isMac: true,
          meta: true,
        ),
        isTrue,
      );
      expect(
        debugIsRightRailNextTabChord(
          key: LogicalKeyboardKey.arrowRight,
          isMac: true,
          ctrl: true,
        ),
        isFalse,
      );
      expect(
        debugIsRightRailNextTabChord(
          key: LogicalKeyboardKey.arrowRight,
          isMac: false,
          ctrl: true,
        ),
        isTrue,
      );
      expect(
        debugIsRightRailPreviousTabChord(
          key: LogicalKeyboardKey.arrowLeft,
          isMac: false,
          ctrl: true,
        ),
        isTrue,
      );
    },
  );

  testWidgets('PageDown from Explorer focuses the games table after load', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await _openExplorerTab(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);

    expect(argsByTab.values.single.gameId, 'gamebase-0');
  });

  testWidgets('Explorer bottom strip navigation controls are always visible', (
    tester,
  ) async {
    _ignoreExplorerEmptyStateOverflowForTest();
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(
      _harness(
        repository: repository,
        canGoBack: true,
        canGoForward: true,
        onFirstMove: () {},
        onPreviousMove: () {},
        onNextMove: () {},
        onLastMove: () {},
        onPreviousGame: () {},
        onNextGame: () {},
        height: 1000,
      ),
    );
    await tester.pump();

    expect(
      find.byIcon(Icons.keyboard_double_arrow_left_rounded),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.first_page_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byIcon(Icons.last_page_rounded), findsOneWidget);
    expect(
      find.byIcon(Icons.keyboard_double_arrow_right_rounded),
      findsOneWidget,
    );

    await _openExplorerFromStripIcon(tester);

    expect(
      find.byIcon(Icons.keyboard_double_arrow_left_rounded),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.first_page_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byIcon(Icons.last_page_rounded), findsOneWidget);
    expect(
      find.byIcon(Icons.keyboard_double_arrow_right_rounded),
      findsOneWidget,
    );
    await _drainStripTestTimers(tester);
  });

  testWidgets('Explorer bottom strip disables unavailable move controls', (
    tester,
  ) async {
    _ignoreExplorerEmptyStateOverflowForTest();
    final repository = _FakeExplorerRepository();
    var firstMoves = 0;
    var previousMoves = 0;
    var nextMoves = 0;
    var lastMoves = 0;

    await tester.pumpWidget(
      _harness(
        repository: repository,
        canGoBack: false,
        canGoForward: false,
        onFirstMove: () => firstMoves += 1,
        onPreviousMove: () => previousMoves += 1,
        onNextMove: () => nextMoves += 1,
        onLastMove: () => lastMoves += 1,
        height: 1000,
      ),
    );
    await _openExplorerFromStripIcon(tester);

    await tester.tap(find.byIcon(Icons.first_page_rounded));
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.tap(find.byIcon(Icons.last_page_rounded));
    await tester.pump();

    expect(firstMoves, 0);
    expect(previousMoves, 0);
    expect(nextMoves, 0);
    expect(lastMoves, 0);
    await _drainStripTestTimers(tester);
  });

  testWidgets('Explorer bottom strip invokes enabled navigation callbacks', (
    tester,
  ) async {
    _ignoreExplorerEmptyStateOverflowForTest();
    final repository = _FakeExplorerRepository();
    var firstMoves = 0;
    var previousMoves = 0;
    var nextMoves = 0;
    var lastMoves = 0;
    var previousGames = 0;
    var nextGames = 0;

    await tester.pumpWidget(
      _harness(
        repository: repository,
        canGoBack: true,
        canGoForward: true,
        onFirstMove: () => firstMoves += 1,
        onPreviousMove: () => previousMoves += 1,
        onNextMove: () => nextMoves += 1,
        onLastMove: () => lastMoves += 1,
        onPreviousGame: () => previousGames += 1,
        onNextGame: () => nextGames += 1,
        height: 1000,
      ),
    );
    await _openExplorerFromStripIcon(tester);

    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left_rounded));
    await tester.tap(find.byIcon(Icons.first_page_rounded));
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.tap(find.byIcon(Icons.last_page_rounded));
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right_rounded));
    await tester.pump();

    expect(previousGames, 1);
    expect(firstMoves, 1);
    expect(previousMoves, 1);
    expect(nextMoves, 1);
    expect(lastMoves, 1);
    expect(nextGames, 1);
    await _drainStripTestTimers(tester);
  });

  testWidgets(
    'ArrowDown inside Explorer games keeps the selected game visible',
    (tester) async {
      final repository = _FakeExplorerRepository();

      await tester.pumpWidget(_harness(repository: repository));
      await _openExplorerTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();

      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpAndSettle();

      expect(find.text('Alpha12').hitTestable(), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      final argsByTab = container.read(boardTabGameArgsByTabIdProvider);
      expect(argsByTab.values.single.gameId, 'gamebase-12');
    },
  );

  testWidgets('Explorer moves table right arrow plays the focused move', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final playedMoves = <String>[];

    await tester.pumpWidget(
      _harness(repository: repository, onPlayUciMove: playedMoves.add),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final rightHandled = await tester.sendKeyEvent(
      LogicalKeyboardKey.arrowRight,
    );
    await tester.pump();
    expect(rightHandled, isTrue);
    expect(playedMoves, [_legalFirstMoves.last]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final secondRightHandled = await tester.sendKeyEvent(
      LogicalKeyboardKey.arrowRight,
    );
    await tester.pump();
    expect(secondRightHandled, isTrue);
    expect(playedMoves, [
      _legalFirstMoves.last,
      _legalFirstMoves[_legalFirstMoves.length - 2],
    ]);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
    expect(container.read(rightRailActivePageProvider('__none__')), 1);
  });

  testWidgets(
    'Explorer moves table right arrow keeps Explorer after board updates',
    (tester) async {
      final repository = _FakeExplorerRepository();
      final playedMoves = <String>[];

      await tester.pumpWidget(
        _statefulHarness(
          repository: repository,
          playedMoves: playedMoves,
          tabId: 'board-tab',
          recreatePanelOnPlay: true,
        ),
      );
      await _openExplorerTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(playedMoves, [_legalFirstMoves.last]);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      expect(container.read(rightRailActivePageProvider('board-tab')), 1);
    },
  );

  testWidgets('Explorer games table left arrow steps notation back', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final playedMoves = <String>[];
    final notationSteps = <int>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPlayUciMove: playedMoves.add,
        onNotationStep: (delta) {
          notationSteps.add(delta);
          return false;
        },
      ),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();

    final leftHandled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(leftHandled, isTrue);
    expect(notationSteps, [-1]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);
    expect(argsByTab.values.single.gameId, 'gamebase-1');
    expect(playedMoves, isEmpty);
  });

  testWidgets('Explorer Shift+ArrowRight switches from moves to games', (
    tester,
  ) async {
    // Empty custom map proves the Moves ⇄ Games switch is local to the
    // Explorer surface and does not depend on any default shortcut entry.
    _shortcutMapOverride = const BoardShortcutMap({});
    final repository = _FakeExplorerRepository();
    final playedMoves = <String>[];

    await tester.pumpWidget(
      _harness(repository: repository, onPlayUciMove: playedMoves.add),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(handled, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);
    expect(argsByTab.values.single.gameId, 'gamebase-1');
    expect(playedMoves, isEmpty);
  });

  testWidgets('Explorer Shift+ArrowLeft switches from games to moves', (
    tester,
  ) async {
    // Empty custom map proves the Moves ⇄ Games switch is local to the
    // Explorer surface and does not depend on any default shortcut entry.
    _shortcutMapOverride = const BoardShortcutMap({});
    final repository = _FakeExplorerRepository();
    final playedMoves = <String>[];

    await tester.pumpWidget(
      _harness(repository: repository, onPlayUciMove: playedMoves.add),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(handled, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
    expect(playedMoves, [_legalFirstMoves[_legalFirstMoves.length - 2]]);
  });

  testWidgets('Explorer tab lets Space bubble to the board shortcut', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final playedMoves = <String>[];
    final previewedLines = <_PreviewLineCall>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPlayUciMove: playedMoves.add,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final movesHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 40));
    expect(movesHandled, isFalse);
    expect(playedMoves, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();

    final gamesHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 40));
    expect(gamesHandled, isFalse);
    expect(previewedLines, isEmpty);
  });

  testWidgets('Space plays the engine move from every right rail tab', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    var engineMovePlays = 0;

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPlayEngineMove: () => engineMovePlays += 1,
      ),
    );
    await tester.pump();

    final notationHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(notationHandled, isTrue);
    expect(engineMovePlays, 1);

    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final explorerHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(explorerHandled, isTrue);
    expect(engineMovePlays, 2);

    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final gamesHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(gamesHandled, isTrue);
    expect(engineMovePlays, 3);
  });

  testWidgets(
    'Explorer move activation keeps focus after board position changes',
    (tester) async {
      final repository = _FakeExplorerRepository();
      final playedMoves = <String>[];

      await tester.pumpWidget(
        _statefulHarness(repository: repository, playedMoves: playedMoves),
      );
      await _openExplorerTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(playedMoves, hasLength(1));

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('MOVE'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();

      expect(playedMoves, hasLength(2));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      expect(container.read(rightRailActivePageProvider('__none__')), 1);
    },
  );

  testWidgets('Alt+Arrow switches the right rail top-level tab', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('MOVE'), findsOneWidget);
    expect(find.text('Opening Explorer'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 2);
  });

  testWidgets('Meta+Arrow switches the right rail top-level tab', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('MOVE'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    var container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 2);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 1);
  });

  testWidgets('Meta+Arrow cycles between all right rail tabs', (tester) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(container.read(rightRailActivePageProvider('__none__')), 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(container.read(rightRailActivePageProvider('__none__')), 2);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(container.read(rightRailActivePageProvider('__none__')), 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(container.read(rightRailActivePageProvider('__none__')), 0);
  });

  testWidgets('Meta+Greater switches from Notation to Explorer', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    _shortcutMapOverride = BoardShortcutMap({
      ...defaultBoardShortcuts(),
      BoardActionKey.rightRailNextTab: [
        KeyChord(
          keyId: LogicalKeyboardKey.arrowRight.keyId,
          meta: true,
          crossPlatform: true,
        ),
      ],
    });

    await tester.pumpWidget(_harness(repository: repository));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 1);
    expect(find.text('MOVE'), findsOneWidget);
  });

  testWidgets('Right rail tab labels stay stable in compact width', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository, width: 480));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Notation'), findsWidgets);
    expect(find.text('Explorer'), findsOneWidget);
    expect(find.text('Games'), findsOneWidget);
    expect(find.text('Moves'), findsNothing);
    expect(find.text('Book'), findsNothing);
  });

  testWidgets('Meta+Period also switches from Notation to Explorer', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 1);
    expect(find.text('MOVE'), findsOneWidget);
  });

  testWidgets('Notation plain horizontal arrows never switch right rail tabs', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final steps = <int>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onNotationStep: (delta) {
          steps.add(delta);
          return false;
        },
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(steps, [1]);
    expect(container.read(rightRailActivePageProvider('__none__')), 0);
    expect(find.text('MOVE'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(steps, [1, -1]);
    expect(container.read(rightRailActivePageProvider('__none__')), 0);
    expect(find.text('MOVE'), findsNothing);
  });

  testWidgets('Notation non-tab modified horizontal arrows stay in Notation', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 0);
    expect(find.text('MOVE'), findsNothing);
  });

  testWidgets('Notation Meta+Arrow switches to Explorer', (tester) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 1);
    expect(find.text('MOVE'), findsOneWidget);
  });

  testWidgets('Notation stays selected when board position changes', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_positionChangingHarness(repository: repository));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Advance'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 0);
    expect(find.text('MOVE'), findsNothing);
  });

  testWidgets(
    'Plain Notation arrow stays in Notation after visiting Explorer',
    (tester) async {
      final repository = _FakeExplorerRepository();
      final steps = <int>[];
      final notationLines = <NotationVerticalDirection>[];
      final previewedMoves = <String>[];

      await tester.pumpWidget(
        _harness(
          repository: repository,
          onPreviewUciMove: previewedMoves.add,
          onNotationVertical: notationLines.add,
          onNotationStep: (delta) {
            steps.add(delta);
            return false;
          },
        ),
      );
      await _openExplorerTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('MOVE'), findsOneWidget);

      await tester.tap(find.text('Notation'));
      await tester.pumpAndSettle();

      previewedMoves.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      expect(steps, [1]);
      expect(container.read(rightRailActivePageProvider('__none__')), 0);
      expect(find.text('MOVE'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(notationLines, [NotationVerticalDirection.down]);
      expect(previewedMoves, isEmpty);
      expect(container.read(rightRailActivePageProvider('__none__')), 0);
    },
  );

  testWidgets('Inactive Explorer does not reactivate after notation changes', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_positionChangingHarness(repository: repository));
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('MOVE'), findsOneWidget);

    await tester.tap(find.text('Notation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advance'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 0);
    expect(find.text('MOVE'), findsNothing);
  });

  testWidgets('Clicking notation content stays in the Notation tab', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final taps = <int>[];

    await tester.pumpWidget(
      _notationTapHarness(repository: repository, taps: taps),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('notation-move')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(taps, [1]);
    expect(container.read(rightRailActivePageProvider('__none__')), 0);
    expect(find.text('MOVE'), findsNothing);
  });

  testWidgets('Explorer move focus waits for explicit activation', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final playedMoves = <String>[];
    final previewedMoves = <String>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPlayUciMove: playedMoves.add,
        onPreviewUciMove: previewedMoves.add,
      ),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    previewedMoves.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(playedMoves, isEmpty);
    expect(previewedMoves, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(playedMoves, isEmpty);
    expect(previewedMoves, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(playedMoves, [_legalFirstMoves[_legalFirstMoves.length - 3]]);
    expect(previewedMoves, isEmpty);
  });

  testWidgets('Explorer moves table left arrow steps notation back', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final playedMoves = <String>[];
    final previewedMoves = <String>[];
    final notationSteps = <int>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPlayUciMove: playedMoves.add,
        onPreviewUciMove: previewedMoves.add,
        onNotationStep: (delta) {
          notationSteps.add(delta);
          return false;
        },
      ),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    previewedMoves.clear();

    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 40));

    expect(handled, isTrue);
    expect(notationSteps, [-1]);
    expect(playedMoves, isEmpty);
    expect(previewedMoves, isEmpty);
  });

  testWidgets('Explorer games hover stays passive until click selection', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedMoves = <String>[];
    final previewedLines = <_PreviewLineCall>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPreviewUciMove: previewedMoves.add,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(previewedMoves, isEmpty);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Alpha0'))),
    );
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));
    expect(previewedLines, isEmpty);

    await tester.tap(find.text('Alpha0'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(previewedLines, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines, isNotEmpty);
    expect(previewedLines.last.autoplay, isFalse);
    expect(previewedLines.last.step, 0);
    expect(previewedLines.last.ucis.first, 'e2e4');

    await tester.sendEventToBinding(pointer.hover(const Offset(-1000, -1000)));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('Games tab keyboard selection waits for move focus', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedLines = <_PreviewLineCall>[];
    const firstMoveKey = ValueKey<String>(
      'position-game-notation-active-games-gamebase-1-0',
    );
    const secondMoveKey = ValueKey<String>(
      'position-game-notation-active-games-gamebase-1-1',
    );

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines, isEmpty);

    final spaceHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 40));

    expect(spaceHandled, isFalse);
    expect(previewedLines, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines, isNotEmpty);
    expect(previewedLines.last.autoplay, isFalse);
    expect(previewedLines.last.step, 0);
    expect(find.byKey(firstMoveKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines.last.autoplay, isFalse);
    expect(previewedLines.last.step, 1);
    expect(find.byKey(secondMoveKey), findsOneWidget);

    await _openExplorerTab(tester);
    await tester.pumpAndSettle();
    await _openGamesTab(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(secondMoveKey).hitTestable(), findsOneWidget);
  });

  testWidgets('Games tab defaults to first row without autoplaying', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedLines = <_PreviewLineCall>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(previewedLines, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);

    expect(argsByTab.values.single.gameId, 'gamebase-0');
  });

  testWidgets('Games tab shows bottom filters and applies them', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('LV'), findsOneWidget);
    expect(find.text('Rapid'), findsOneWidget);

    await tester.tap(find.text('Rapid'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(repository.positionGameCalls.last.timeControl, TimeControl.rapid);
  });

  testWidgets('Games tab left arrow at row boundary steps notation back', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedLines = <_PreviewLineCall>[];
    final notationSteps = <int>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
        onNotationStep: (delta) {
          notationSteps.add(delta);
          return false;
        },
      ),
    );
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 40));

    expect(handled, isTrue);
    expect(notationSteps, [-1]);
    expect(previewedLines, isEmpty);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 2);
  });

  testWidgets('Games tab exits inline notation before row navigation', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    const firstMoveKey = ValueKey<String>(
      'position-game-notation-active-games-gamebase-0-0',
    );

    await tester.pumpWidget(_harness(repository: repository));
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.byKey(firstMoveKey), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(firstMoveKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(firstMoveKey), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);
    expect(argsByTab.values.single.gameId, 'gamebase-1');
  });

  testWidgets('Games tab hover focuses without previewing or catching Space', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedLines = <_PreviewLineCall>[];
    const autoplayMoveKey = ValueKey<String>(
      'position-game-notation-active-games-gamebase-0-2',
    );

    await tester.pumpWidget(
      _harness(
        repository: repository,
        previewLineStep: 2,
        previewLineAutoplay: true,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final pointer = TestPointer(2, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Alpha0'))),
    );
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines, isEmpty);
    expect(find.byKey(autoplayMoveKey), findsNothing);

    final spaceHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 40));

    expect(spaceHandled, isFalse);
    expect(previewedLines, isEmpty);
    expect(find.byKey(autoplayMoveKey), findsNothing);
  });

  testWidgets('Games tab notation moves are clickable embedded targets', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedLines = <_PreviewLineCall>[];
    const secondTokenKey = ValueKey<String>(
      'position-game-notation-token-games-gamebase-0-1',
    );
    const secondActiveKey = ValueKey<String>(
      'position-game-notation-active-games-gamebase-0-1',
    );
    const thirdActiveKey = ValueKey<String>(
      'position-game-notation-active-games-gamebase-0-2',
    );

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(secondTokenKey));
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines, isNotEmpty);
    expect(previewedLines.last.autoplay, isFalse);
    expect(previewedLines.last.step, 1);
    expect(find.byKey(secondActiveKey), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));

    expect(previewedLines.last.autoplay, isFalse);
    expect(previewedLines.last.step, 2);
    expect(find.byKey(thirdActiveKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'gamebase-0');
    expect(args.initialFen, _fenAfterUcis(['e2e4', 'e7e5', 'g1f3']));
  });

  testWidgets(
    'Games tab Enter on inline notation asks before inserting moves',
    (tester) async {
      final repository = _FakeExplorerRepository();
      final insertedLines = <ExplorerContinuationInsertion>[];
      const secondTokenKey = ValueKey<String>(
        'position-game-notation-token-games-gamebase-0-1',
      );

      await tester.pumpWidget(
        _harness(repository: repository, onPlayUciLine: insertedLines.add),
      );
      await _openGamesTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(secondTokenKey));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 240));

      expect(find.text('Use continuation…'), findsOneWidget);
      expect(find.text('Insert moves'), findsOneWidget);
      expect(find.text('Open game'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(insertedLines.map((line) => line.ucis), [
        ['e2e4', 'e7e5'],
      ]);
      expect(
        insertedLines.single.sourceLabel,
        'Alpha0 vs Beta0, Keyboard UX Test, 2025-02-01',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
      expect(container.read(rightRailActivePageProvider('__none__')), 2);
    },
  );

  testWidgets('Games tab insertion keeps Games after parent board updates', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final insertedLines = <ExplorerContinuationInsertion>[];
    const secondTokenKey = ValueKey<String>(
      'position-game-notation-token-games-gamebase-0-1',
    );

    await tester.pumpWidget(
      _statefulLineInsertionHarness(
        repository: repository,
        insertedLines: insertedLines,
        tabId: 'board-tab',
        recreatePanelOnInsert: true,
      ),
    );
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(secondTokenKey));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 240));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(insertedLines.map((line) => line.ucis), [
      ['e2e4', 'e7e5'],
    ]);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('board-tab')), 2);
  });

  testWidgets(
    'Games tab vertical arrows start the next card at first inline move',
    (tester) async {
      final repository = _FakeExplorerRepository();
      final previewedLines = <_PreviewLineCall>[];
      const secondTokenKey = ValueKey<String>(
        'position-game-notation-token-games-gamebase-0-1',
      );
      const row0ActiveKey = ValueKey<String>(
        'position-game-notation-active-games-gamebase-0-1',
      );
      const row1ActiveKey = ValueKey<String>(
        'position-game-notation-active-games-gamebase-1-0',
      );
      const row1SecondMoveKey = ValueKey<String>(
        'position-game-notation-active-games-gamebase-1-1',
      );

      await tester.pumpWidget(
        _harness(
          repository: repository,
          onPreviewUciLine:
              (ucis, {autoplay = true, step}) =>
                  previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
        ),
      );
      await _openGamesTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(secondTokenKey));
      await tester.pump(const Duration(milliseconds: 40));

      expect(previewedLines.last.step, 1);
      expect(find.byKey(row0ActiveKey), findsOneWidget);

      previewedLines.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 40));

      expect(previewedLines, isNotEmpty);
      expect(previewedLines.last.autoplay, isFalse);
      expect(previewedLines.last.step, 0);
      expect(find.byKey(row0ActiveKey), findsNothing);
      expect(find.byKey(row1ActiveKey), findsOneWidget);
      expect(find.byKey(row1SecondMoveKey), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(row0ActiveKey), findsNothing);
      expect(find.byKey(row1ActiveKey), findsNothing);
      expect(
        find.byKey(
          const ValueKey<String>(
            'position-game-notation-active-games-gamebase-0-0',
          ),
        ),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      final args =
          container.read(boardTabGameArgsByTabIdProvider).values.single;
      expect(args.gameId, 'gamebase-1');
      expect(args.initialFen, _fenAfterUcis(['e2e4']));
    },
  );

  testWidgets('Games tab lets Space bubble to the board shortcut', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedLines = <_PreviewLineCall>[];

    await tester.pumpWidget(
      _previewFeedbackHarness(
        repository: repository,
        previewedLines: previewedLines,
      ),
    );
    await _openGamesTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final spaceHandled = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 40));

    expect(spaceHandled, isFalse);
    expect(previewedLines, isEmpty);
  });

  testWidgets('Explorer games Enter opens at active inline move', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedLines = <_PreviewLineCall>[];

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));
    expect(previewedLines.last.step, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;

    expect(args.gameId, 'gamebase-0');
    expect(args.initialFen, _fenAfterUcis(['e2e4']));
  });

  testWidgets('Explorer games Enter on inline notation asks before inserting', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final insertedLines = <ExplorerContinuationInsertion>[];

    await tester.pumpWidget(
      _harness(repository: repository, onPlayUciLine: insertedLines.add),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.text('Use continuation…'), findsOneWidget);
    expect(find.text('Insert moves'), findsOneWidget);
    expect(find.text('Open game'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(insertedLines.map((line) => line.ucis), [
      ['e2e4'],
    ]);
    expect(
      insertedLines.single.sourceLabel,
      'Alpha0 vs Beta0, Keyboard UX Test, 2025-02-01',
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
    expect(container.read(rightRailActivePageProvider('__none__')), 1);
  });

  testWidgets(
    'Explorer games insertion keeps Explorer after parent board updates',
    (tester) async {
      final repository = _FakeExplorerRepository();
      final insertedLines = <ExplorerContinuationInsertion>[];

      await tester.pumpWidget(
        _statefulLineInsertionHarness(
          repository: repository,
          insertedLines: insertedLines,
          tabId: 'board-tab',
          recreatePanelOnInsert: true,
        ),
      );
      await _openExplorerTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 240));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(insertedLines.map((line) => line.ucis), [
        ['e2e4'],
      ]);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      expect(container.read(rightRailActivePageProvider('board-tab')), 1);
    },
  );

  testWidgets('Explorer games row has an embedded continuation cursor', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final previewedMoves = <String>[];
    final previewedLines = <_PreviewLineCall>[];
    const explorerMoveKey = ValueKey<String>(
      'position-game-notation-active-explorer-gamebase-1-0',
    );
    const nextExplorerMoveKey = ValueKey<String>(
      'position-game-notation-active-explorer-gamebase-2-0',
    );

    await tester.pumpWidget(
      _harness(
        repository: repository,
        onPreviewUciMove: previewedMoves.add,
        onPreviewUciLine:
            (ucis, {autoplay = true, step}) =>
                previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
      ),
    );
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(previewedLines, isEmpty);
    expect(find.byKey(explorerMoveKey), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 40));
    expect(previewedLines.last.autoplay, isFalse);
    expect(previewedLines.last.step, 0);
    expect(find.byKey(explorerMoveKey), findsOneWidget);
    final embeddedPreviewCount = previewedLines.length;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 40));
    expect(previewedLines.length, greaterThan(embeddedPreviewCount));
    expect(previewedLines.last.autoplay, isFalse);
    expect(previewedLines.last.step, 0);
    expect(find.byKey(explorerMoveKey), findsNothing);
    expect(find.byKey(nextExplorerMoveKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(nextExplorerMoveKey), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);

    expect(previewedMoves, isEmpty);
    expect(argsByTab.values.single.gameId, 'gamebase-2');
  });

  testWidgets(
    'Explorer games vertical arrows start the next card at first inline move',
    (tester) async {
      final repository = _FakeExplorerRepository();
      final previewedLines = <_PreviewLineCall>[];
      const row0FirstMoveKey = ValueKey<String>(
        'position-game-notation-active-explorer-gamebase-0-0',
      );
      const row0SecondMoveKey = ValueKey<String>(
        'position-game-notation-active-explorer-gamebase-0-1',
      );
      const row1FirstMoveKey = ValueKey<String>(
        'position-game-notation-active-explorer-gamebase-1-0',
      );
      const row1SecondMoveKey = ValueKey<String>(
        'position-game-notation-active-explorer-gamebase-1-1',
      );

      await tester.pumpWidget(
        _harness(
          repository: repository,
          onPreviewUciLine:
              (ucis, {autoplay = true, step}) =>
                  previewedLines.add(_PreviewLineCall(ucis, autoplay, step)),
        ),
      );
      await _openExplorerTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 40));

      expect(previewedLines.last.step, 1);
      expect(find.byKey(row0SecondMoveKey), findsOneWidget);

      previewedLines.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 40));

      expect(previewedLines, isNotEmpty);
      expect(previewedLines.last.autoplay, isFalse);
      expect(previewedLines.last.step, 0);
      expect(find.byKey(row0SecondMoveKey), findsNothing);
      expect(find.byKey(row1FirstMoveKey), findsOneWidget);
      expect(find.byKey(row1SecondMoveKey), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(row1SecondMoveKey), findsOneWidget);

      previewedLines.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 40));

      expect(previewedLines, isNotEmpty);
      expect(previewedLines.last.autoplay, isFalse);
      expect(previewedLines.last.step, 0);
      expect(find.byKey(row0FirstMoveKey), findsOneWidget);
      expect(find.byKey(row0SecondMoveKey), findsNothing);
    },
  );

  testWidgets('modified vertical arrows bubble out of Notation tab', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();
    final notationSteps = <NotationVerticalDirection>[];

    await tester.pumpWidget(
      _harness(repository: repository, onNotationVertical: notationSteps.add),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(notationSteps, isEmpty);
  });

  testWidgets('Explorer stays selected when board position changes', (
    tester,
  ) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_positionChangingHarness(repository: repository));
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotationOpeningPanel)),
    );
    expect(container.read(rightRailActivePageProvider('__none__')), 1);

    await tester.tap(find.text('Advance'));
    await tester.pumpAndSettle();

    expect(container.read(rightRailActivePageProvider('__none__')), 1);
  });

  testWidgets(
    'Explorer survives external board move when board pane has focus',
    (tester) async {
      final repository = _FakeExplorerRepository();

      await tester.pumpWidget(
        _externalBoardMoveHarness(repository: repository),
      );
      await _openExplorerTab(tester);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NotationOpeningPanel)),
      );
      expect(container.read(rightRailActivePageProvider('board-tab')), 1);

      await tester.tap(find.text('Focus board'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply move'));
      await tester.pumpAndSettle();

      expect(container.read(rightRailActivePageProvider('board-tab')), 1);
    },
  );

  testWidgets('Explorer keeps the right side as a games table', (tester) async {
    final repository = _FakeExplorerRepository();

    await tester.pumpWidget(_harness(repository: repository));
    await _openExplorerTab(tester);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('MOVE'), findsOneWidget);
    expect(find.text('Opening Explorer'), findsNothing);
    expect(find.text('Alpha0'), findsOneWidget);
    expect(find.text('Explorer notation'), findsNothing);
    expect(find.text('SCORE'), findsOneWidget);
    expect(find.text('NOTATION'), findsOneWidget);
    expect(find.text('ECO'), findsOneWidget);
    expect(find.text('EVENT'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('EVENT')).dx,
      lessThan(tester.getTopLeft(find.text('NOTATION')).dx),
    );
    expect(find.text('RESULT'), findsNothing);
  });
}

Widget _harness({
  required _FakeExplorerRepository repository,
  void Function(String uci)? onPlayUciMove,
  VoidCallback? onPlayEngineMove,
  void Function(ExplorerContinuationInsertion insertion)? onPlayUciLine,
  void Function(String uci)? onPreviewUciMove,
  void Function(List<String> ucis, {bool autoplay, int? step})?
  onPreviewUciLine,
  ValueChanged<NotationVerticalDirection>? onNotationVertical,
  bool Function(int delta)? onNotationStep,
  bool canGoBack = false,
  bool canGoForward = false,
  VoidCallback? onFirstMove,
  VoidCallback? onPreviousMove,
  VoidCallback? onNextMove,
  VoidCallback? onLastMove,
  VoidCallback? onPreviousGame,
  VoidCallback? onNextGame,
  int previewLineStep = 0,
  bool previewLineAutoplay = false,
  double width = 760,
  double height = 360,
}) {
  return ProviderScope(
    overrides: [
      gamebaseRepositoryProvider.overrideWithValue(repository),
      boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
      keyboardShortcutsProvider.overrideWith(
        _TestKeyboardShortcutsNotifier.new,
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: kBackgroundColor,
        body: SizedBox(
          width: width,
          height: height,
          child: NotationOpeningPanel(
            notationChild: const Center(child: Text('Notation')),
            currentFen: _initialFen,
            startingFen: _initialFen,
            lineUcis: const <String>[],
            onPlayUciMove: onPlayUciMove ?? (_) {},
            onPlayEngineMove: onPlayEngineMove,
            onPlayUciLine: onPlayUciLine,
            onPreviewUciMove: onPreviewUciMove,
            onPreviewUciLine: onPreviewUciLine,
            previewLineStep: previewLineStep,
            previewLineAutoplay: previewLineAutoplay,
            onNotationVertical: onNotationVertical,
            onNotationStep: onNotationStep,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            onFirstMove: onFirstMove,
            onPreviousMove: onPreviousMove,
            onNextMove: onNextMove,
            onLastMove: onLastMove,
            onPreviousGame: onPreviousGame,
            onNextGame: onNextGame,
          ),
        ),
      ),
    ),
  );
}

void _ignoreExplorerEmptyStateOverflowForTest() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
      return;
    }
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);
}

Future<void> _drainStripTestTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
}

class _PreviewLineCall {
  const _PreviewLineCall(this.ucis, this.autoplay, this.step);

  final List<String> ucis;
  final bool autoplay;
  final int? step;
}

Widget _statefulHarness({
  required _FakeExplorerRepository repository,
  required List<String> playedMoves,
  String? tabId,
  bool recreatePanelOnPlay = false,
}) {
  return _StatefulExplorerHarness(
    repository: repository,
    playedMoves: playedMoves,
    tabId: tabId,
    recreatePanelOnPlay: recreatePanelOnPlay,
  );
}

Widget _statefulLineInsertionHarness({
  required _FakeExplorerRepository repository,
  required List<ExplorerContinuationInsertion> insertedLines,
  String? tabId,
  bool recreatePanelOnInsert = false,
}) {
  return _StatefulLineInsertionHarness(
    repository: repository,
    insertedLines: insertedLines,
    tabId: tabId,
    recreatePanelOnInsert: recreatePanelOnInsert,
  );
}

Widget _previewFeedbackHarness({
  required _FakeExplorerRepository repository,
  required List<_PreviewLineCall> previewedLines,
}) {
  return _PreviewFeedbackHarness(
    repository: repository,
    previewedLines: previewedLines,
  );
}

Widget _positionChangingHarness({required _FakeExplorerRepository repository}) {
  return _PositionChangingHarness(repository: repository);
}

Widget _externalBoardMoveHarness({
  required _FakeExplorerRepository repository,
}) {
  return _ExternalBoardMoveHarness(repository: repository);
}

Widget _notationTapHarness({
  required _FakeExplorerRepository repository,
  required List<int> taps,
}) {
  return _NotationTapHarness(repository: repository, taps: taps);
}

class _PositionChangingHarness extends StatefulWidget {
  const _PositionChangingHarness({required this.repository});

  final _FakeExplorerRepository repository;

  @override
  State<_PositionChangingHarness> createState() =>
      _PositionChangingHarnessState();
}

class _PositionChangingHarnessState extends State<_PositionChangingHarness> {
  List<String> _lineUcis = const <String>[];

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(widget.repository),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: Column(
            children: [
              TextButton(
                onPressed: () {
                  setState(() => _lineUcis = const <String>['e2e4']);
                },
                child: const Text('Advance'),
              ),
              SizedBox(
                width: 760,
                height: 360,
                child: NotationOpeningPanel(
                  notationChild: const Center(child: Text('Notation')),
                  currentFen: _initialFen,
                  startingFen: _initialFen,
                  lineUcis: _lineUcis,
                  onPlayUciMove: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExternalBoardMoveHarness extends StatefulWidget {
  const _ExternalBoardMoveHarness({required this.repository});

  final _FakeExplorerRepository repository;

  @override
  State<_ExternalBoardMoveHarness> createState() =>
      _ExternalBoardMoveHarnessState();
}

class _ExternalBoardMoveHarnessState extends State<_ExternalBoardMoveHarness> {
  String _fen = _initialFen;
  List<String> _lineUcis = const <String>[];
  final FocusNode _boardFocus = FocusNode(debugLabel: 'fake-board');

  void _applyMove() {
    setState(() {
      _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      _lineUcis = const <String>['e2e4'];
    });
    _boardFocus.requestFocus();
  }

  @override
  void dispose() {
    _boardFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(widget.repository),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: Column(
            children: [
              Focus(
                focusNode: _boardFocus,
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => _boardFocus.requestFocus(),
                      child: const Text('Focus board'),
                    ),
                    TextButton(
                      onPressed: _applyMove,
                      child: const Text('Apply move'),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 760,
                height: 360,
                child: NotationOpeningPanel(
                  tabId: 'board-tab',
                  notationChild: const Center(child: Text('Notation')),
                  currentFen: _fen,
                  startingFen: _initialFen,
                  lineUcis: _lineUcis,
                  onPlayUciMove: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewFeedbackHarness extends StatefulWidget {
  const _PreviewFeedbackHarness({
    required this.repository,
    required this.previewedLines,
  });

  final _FakeExplorerRepository repository;
  final List<_PreviewLineCall> previewedLines;

  @override
  State<_PreviewFeedbackHarness> createState() =>
      _PreviewFeedbackHarnessState();
}

class _PreviewFeedbackHarnessState extends State<_PreviewFeedbackHarness> {
  int _previewLineStep = 0;
  bool _previewLineAutoplay = false;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(widget.repository),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: SizedBox(
            width: 760,
            height: 360,
            child: NotationOpeningPanel(
              notationChild: const Center(child: Text('Notation')),
              currentFen: _initialFen,
              startingFen: _initialFen,
              lineUcis: const <String>[],
              previewLineStep: _previewLineStep,
              previewLineAutoplay: _previewLineAutoplay,
              onPlayUciMove: (_) {},
              onPreviewUciLine: (ucis, {autoplay = true, step}) {
                widget.previewedLines.add(
                  _PreviewLineCall(ucis, autoplay, step),
                );
                setState(() {
                  _previewLineStep = step ?? 0;
                  _previewLineAutoplay = autoplay;
                });
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NotationTapHarness extends StatefulWidget {
  const _NotationTapHarness({required this.repository, required this.taps});

  final _FakeExplorerRepository repository;
  final List<int> taps;

  @override
  State<_NotationTapHarness> createState() => _NotationTapHarnessState();
}

class _NotationTapHarnessState extends State<_NotationTapHarness> {
  List<String> _lineUcis = const <String>[];

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(widget.repository),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: SizedBox(
            width: 760,
            height: 360,
            child: NotationOpeningPanel(
              notationChild: Center(
                child: GestureDetector(
                  key: const ValueKey<String>('notation-move'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    widget.taps.add(1);
                    setState(() {
                      _lineUcis = const <String>['e2e4'];
                    });
                  },
                  child: const Text('Notation move'),
                ),
              ),
              currentFen: _initialFen,
              startingFen: _initialFen,
              lineUcis: _lineUcis,
              onPlayUciMove: (_) {},
            ),
          ),
        ),
      ),
    );
  }
}

class _StatefulExplorerHarness extends StatefulWidget {
  const _StatefulExplorerHarness({
    required this.repository,
    required this.playedMoves,
    this.tabId,
    this.recreatePanelOnPlay = false,
  });

  final _FakeExplorerRepository repository;
  final List<String> playedMoves;
  final String? tabId;
  final bool recreatePanelOnPlay;

  @override
  State<_StatefulExplorerHarness> createState() =>
      _StatefulExplorerHarnessState();
}

class _StatefulExplorerHarnessState extends State<_StatefulExplorerHarness> {
  String _fen = _initialFen;
  List<String> _lineUcis = const <String>[];
  int _panelGeneration = 0;

  void _play(String uci) {
    widget.playedMoves.add(uci);
    setState(() {
      _fen = _initialFen;
      _lineUcis = List<String>.unmodifiable([..._lineUcis, uci]);
      if (widget.recreatePanelOnPlay) _panelGeneration++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(widget.repository),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: SizedBox(
            width: 760,
            height: 360,
            child: NotationOpeningPanel(
              key:
                  widget.recreatePanelOnPlay
                      ? ValueKey<String>('right-rail-$_panelGeneration')
                      : null,
              tabId: widget.tabId,
              notationChild: const Center(child: Text('Notation')),
              currentFen: _fen,
              startingFen: _initialFen,
              lineUcis: _lineUcis,
              onPlayUciMove: _play,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatefulLineInsertionHarness extends StatefulWidget {
  const _StatefulLineInsertionHarness({
    required this.repository,
    required this.insertedLines,
    this.tabId,
    this.recreatePanelOnInsert = false,
  });

  final _FakeExplorerRepository repository;
  final List<ExplorerContinuationInsertion> insertedLines;
  final String? tabId;
  final bool recreatePanelOnInsert;

  @override
  State<_StatefulLineInsertionHarness> createState() =>
      _StatefulLineInsertionHarnessState();
}

class _StatefulLineInsertionHarnessState
    extends State<_StatefulLineInsertionHarness> {
  List<String> _lineUcis = const <String>[];
  int _panelGeneration = 0;

  void _insert(ExplorerContinuationInsertion insertion) {
    widget.insertedLines.add(insertion);
    setState(() {
      _lineUcis = List<String>.unmodifiable([..._lineUcis, ...insertion.ucis]);
      if (widget.recreatePanelOnInsert) _panelGeneration++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(widget.repository),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: SizedBox(
            width: 760,
            height: 360,
            child: NotationOpeningPanel(
              key:
                  widget.recreatePanelOnInsert
                      ? ValueKey<String>('right-rail-$_panelGeneration')
                      : null,
              tabId: widget.tabId,
              notationChild: const Center(child: Text('Notation')),
              currentFen: _fenAfterUcis(_lineUcis),
              startingFen: _initialFen,
              lineUcis: _lineUcis,
              onPlayUciMove: (_) {},
              onPlayUciLine: _insert,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openExplorerTab(WidgetTester tester) async {
  await tester.pump();
  final explorerTab = find.text('Explorer');
  final compactExplorerTab = find.text('Book');
  await tester.tap(
    explorerTab.evaluate().isNotEmpty ? explorerTab : compactExplorerTab,
  );
  await tester.pumpAndSettle();
}

Future<void> _openExplorerFromStripIcon(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(find.byIcon(Icons.menu_book_outlined).first);
  await tester.pump();
}

Future<void> _openGamesTab(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(find.text('Games'));
  await tester.pumpAndSettle();
}

String _fenAfterUcis(List<String> ucis) {
  Position position = Chess.initial;
  for (final uci in ucis) {
    position = position.play(NormalMove.fromUci(uci));
  }
  return position.fen;
}

class _FakeExplorerRepository extends GamebaseRepository {
  _FakeExplorerRepository() : super(Dio(), baseUrl: 'http://localhost');

  final List<_CapturedPositionGamesQuery> positionGameCalls = [];

  @override
  Future<GamebaseResponse> getMoveAggregates({
    required String fen,
    List<String> moves = const [],
    String? playerId,
    TimeControl? timeControl,
    int? minRating,
    int? maxRating,
    String? color,
    String? result,
    int? yearFrom,
    int? yearTo,
    bool? isOnline,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return GamebaseResponse(
      status: 'success',
      data: GamebaseData(
        moves: [
          for (final (i, uci) in _legalFirstMoves.indexed)
            MoveAggregate(
              uci: uci,
              white: 40 + i,
              black: 25,
              draws: 35,
              total: 100 + i,
              lastPlayed: DateTime(2025, 1, 1 + (i % 20)),
            ),
        ],
      ),
    );
  }

  @override
  Future<GamebaseSearchQueryResponse> getPositionGames({
    required String fen,
    List<String> moves = const [],
    String? uci,
    TimeControl? timeControl,
    String? playerId,
    String? color,
    String? result,
    int? minRating,
    int? maxRating,
    int? yearFrom,
    int? yearTo,
    GamebaseSortField? sortBy,
    GamebaseSortDirection? sortDirection,
    bool? isOnline,
    int pageNumber = 0,
    int pageSize = 20,
    int notationPlies = 0,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    positionGameCalls.add(
      _CapturedPositionGamesQuery(timeControl: timeControl),
    );
    return GamebaseSearchQueryResponse(
      status: 'success',
      data: [
        for (var i = 0; i < 25; i++)
          {
            'id': 'gamebase-$i',
            'white': 'Alpha$i',
            'black': 'Beta$i',
            'whiteFed': 'NOR',
            'blackFed': 'USA',
            'whiteTitle': 'GM',
            'blackTitle': 'GM',
            'whiteElo': 2800 - i,
            'blackElo': 2700 + i,
            'result': i.isEven ? '1-0' : '0-1',
            'date': '2025-02-${((i % 20) + 1).toString().padLeft(2, '0')}',
            'event': 'Keyboard UX Test',
            'site': 'Test Site',
            'timeControl': 'BLITZ',
            'isOnline': i.isEven,
            'opening': 'English Opening',
            'variation': 'Symmetrical',
            'eco': 'A29',
            'continuation': const ['e2e4', 'e7e5', 'g1f3'],
          },
      ],
      metadata: GamebasePaginationMetadata(
        pageNumber: pageNumber,
        pageSize: pageSize,
        hasMoreValue: false,
      ),
    );
  }

  @override
  Future<GamebaseGameWithPgn?> getGameWithPgn(String id) async {
    return GamebaseGameWithPgn(
      id: id,
      date: DateTime(2025, 2, 1),
      result: GameResult.whiteWins,
      timeControl: TimeControl.blitz,
      whiteName: 'Alpha',
      blackName: 'Beta',
      pgn:
          '[Event "Keyboard UX Test"]\n'
          '[Site "Test"]\n'
          '[Date "2025.02.01"]\n'
          '[White "Alpha"]\n'
          '[Black "Beta"]\n'
          '[Result "1-0"]\n\n'
          '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0',
    );
  }
}

class _CapturedPositionGamesQuery {
  const _CapturedPositionGamesQuery({this.timeControl});

  final TimeControl? timeControl;
}

const _legalFirstMoves = [
  'a2a3',
  'a2a4',
  'b2b3',
  'b2b4',
  'c2c3',
  'c2c4',
  'd2d3',
  'd2d4',
  'e2e3',
  'e2e4',
  'f2f3',
  'f2f4',
  'g2g3',
  'g2g4',
  'h2h3',
  'h2h4',
  'b1a3',
  'b1c3',
  'g1f3',
  'g1h3',
];

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(useFigurine: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _TestKeyboardShortcutsNotifier extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async {
    return _shortcutMapOverride ?? BoardShortcutMap(defaultBoardShortcuts());
  }
}
