import 'dart:async';
import 'dart:io';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/panes/board_settings_pane.dart';
import 'package:chessever/providers/auto_pin_preferences_provider.dart';
import 'package:chessever/repository/local_storage/auto_pin_preferences/auto_pin_preferences_repository.dart';
import 'package:chessever/desktop/services/engine/pv_san_formatter.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/services/toby/toby_classes.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_analysis_preferences.dart';
import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/widgets/board_wheel_navigation.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/engine_settings_popover.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/toby/what_toby_thinks.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';

/// The whole board pane with the Toby Predicts tab in its engine pane:
/// what reaches the board, what is asked, and how the header and the rail
/// hold their sizes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory databaseDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'chessever-toby-board-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => databaseDirectory.path,
        );
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
    await AppDatabase.instance.database;
  });

  tearDownAll(() async {
    await AppDatabase.instance.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await databaseDirectory.exists()) {
      await databaseDirectory.delete(recursive: true);
    }
  });

  setUp(() {
    _script.value = const TobyReadingState(TobyStatus.thinking);
    _queries.clear();
    _pvIndex = 0;
    _tobyBar = false;
  });

  testWidgets('master pause hides both readings and restores the Toby bar', (tester) async {
    _tobyBar = true;
    await _pumpBoard(tester, toby: false);
    final bar = find.byKey(const ValueKey('e2e_board_toby_bar'));
    expect(bar, findsOneWidget);
    final power = find.byIcon(Icons.power_settings_new_rounded);
    await tester.tap(power);
    await tester.pump();
    expect(bar, findsNothing);
    await tester.tap(find.byIcon(Icons.power_settings_new_outlined));
    await tester.pump(const Duration(milliseconds: 400));
    expect(bar, findsOneWidget);
  });

  group('the Toby bar', () {
    final bar = find.byKey(const ValueKey('e2e_board_toby_bar'));

    testWidgets('sits on the board\'s right at the board\'s height, asks on '
        'the Stockfish tab too, and never moves the board', (tester) async {
      _tobyBar = true;
      await _pumpBoard(tester, toby: false);
      expect(bar, findsOneWidget);
      final board = tester.getRect(find.byType(DesktopChessBoard));
      final barRect = tester.getRect(bar);
      expect(barRect.height, moreOrLessEquals(board.height));
      expect(barRect.top, moreOrLessEquals(board.top));
      expect(barRect.left, moreOrLessEquals(board.right + 12));
      expect(barRect.width, 24);
      // The bar reads the position on the board.
      expect(_queries.map((q) => q.request.moves.length), [4]);
      expect(_queries.single.session, isNotEmpty);
      expect(find.bySemanticsLabel('Toby: no reading'), findsOneWidget);

      _script.value = TobyReadingState.ready(_reading(final_: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.bySemanticsLabel('Toby: White 30%, draw 50%, Black 20%'),
        findsOneWidget,
      );
      expect(tester.getRect(find.byType(DesktopChessBoard)), board);
    });

    testWidgets('with the Toby tab open, the bar and the tab ask about each '
        'position once between them', (tester) async {
      _tobyBar = true;
      await _pumpBoard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      await tester.pump();
      _queries.clear();
      _script.value = TobyReadingState.ready(_reading(final_: true));
      for (var step = 0; step < 3; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump();
      }
      expect(_queries.map((q) => q.request.moves.length).toList(), [1, 2, 3]);
      expect(_queries.map((q) => q.session).toSet(), hasLength(1));
    });

    testWidgets('hidden by its setting: no bar, no room for it, nothing '
        'asked', (tester) async {
      await _pumpBoard(tester, toby: false);
      expect(bar, findsNothing);
      expect(_queries, isEmpty);
    });
  });

  testWidgets('new Board preferences show both analyses even if the legacy engine setting is off', (tester) async {
    _engineOn = false;
    addTearDown(() => _engineOn = true);
    final probe = await _pumpBoard(tester, size: const Size(2400, 820), toby: false);
    // This full Board test leaves the real async SAN formatter in place.
    // The published score proves Stockfish is running independently of whether
    // native background SAN formatting has finished.
    probe.emitEngine(_threeLines, isEvaluating: false);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Stockfish'), findsOneWidget);
    final liveFen = _boardFen(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(BoardPane)));
    expect(probe.notifiers, isNotEmpty);
    expect(container.read(boardEvalProvider(liveFen)).pvs, _threeLines);
    expect(find.text('3.Nf3'), findsOneWidget);
    expect(find.text('60.0%'), findsOneWidget);
    expect(find.text('Played'), findsNothing);
    expect(find.descendant(of: _pvLineFinder, matching: find.textContaining('%')), findsNothing);
  });

  testWidgets('Board gear defaults to three Stockfish lines and remembers a choice', (tester) async {
    await _pumpBoard(tester, toby: false);
    await tester.tap(find.byType(EngineSettingsPopover));
    await tester.pumpAndSettle();
    final gear = find.ancestor(
      of: find.text('Engine lines'),
      matching: find.byWidgetPredicate((widget) =>
          widget.runtimeType.toString() == '_SegmentedRow'),
    );
    Finder line(String value) => find.descendant(of: gear, matching: find.text(value));
    expect(tester.widget<Text>(line('3')).style?.color, kBackgroundColor);
    await tester.tap(line('4'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(line('4')).style?.color, kBackgroundColor);
    final saved = await SharedPreferences.getInstance();
    expect(saved.getInt('desktop.analysis.stockfishLines.v1'), 3);
  });

  testWidgets('Board settings use the same Stockfish line preference as the gear', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1120);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        engineSettingsProviderNew.overrideWith(_EngineWithArrowsOnNotifier.new),
        autoPinPreferencesProvider.overrideWith(_TestAutoPinPreferences.new),
      ],
      child: const MaterialApp(home: Scaffold(body: BoardSettingsPane())),
    ));
    await tester.pumpAndSettle();
    final field = find.ancestor(
      of: find.text('Number of lines'),
      matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SegmentedField'),
    );
    Finder option(String value) => find.descendant(of: field, matching: find.text(value));
    Color? color(String value) => DefaultTextStyle.of(tester.element(option(value))).style.color;
    expect(color('3'), kBackgroundColor);
    await tester.ensureVisible(option('4'));
    await tester.tap(option('4'));
    await tester.pumpAndSettle();
    expect(color('4'), kBackgroundColor);
    final container = ProviderScope.containerOf(tester.element(find.byType(BoardSettingsPane)));
    expect(container.read(boardAnalysisPreferencesProvider).stockfishLineIndex, 3);
  });

  testWidgets('compact Toby credit only appears on its title hover', (tester) async {
    await _pumpBoard(tester, size: const Size(2400, 820), toby: false);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pumpAndSettle();
    expect(find.textContaining(kTobyAttribution, findRichText: true), findsNothing);
    final hover = await _hover(tester, find.text(kTobyFeatureLabel));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining(kTobyAttribution, findRichText: true), findsOneWidget);
    await hover.moveTo(const Offset(5, 5));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining(kTobyAttribution, findRichText: true), findsNothing);
  });

  testWidgets('dragging the analysis divider down shows more Toby moves', (tester) async {
    await _pumpBoard(tester, size: const Size(2400, 820), toby: false);
    _script.value = TobyReadingState.ready(const TobyReading(
      isFinal: true,
      sideToMove: Side.white,
      candidates: [
        TobyCandidate(uci: 'b1c3', san: 'Nc3', probability: 0.3),
        TobyCandidate(uci: 'd2d4', san: 'd4', probability: 0.24),
        TobyCandidate(uci: 'f1b5', san: 'Bb5', probability: 0.2),
        TobyCandidate(uci: 'f1c4', san: 'Bc4', probability: 0.13),
        TobyCandidate(uci: 'f1e2', san: 'Be2', probability: 0.08),
        TobyCandidate(uci: 'h2h3', san: 'h3', probability: 0.05),
      ],
      otherProbability: 0,
      otherMoveCount: 0,
    ));
    await tester.pumpAndSettle();
    final view = find.byType(WhatTobyThinks);
    final nextLine = find.text('3.Bc4');
    final split = find.byWidgetPredicate((widget) => widget is ResizableSplitView &&
        widget.storageKey == desktopEngineRightRailSplitStorageKey);
    expect(tester.widget<ResizableSplitView>(split).gutterColor, kLightGreyColor);
    final before = tester.getRect(view);
    expect(tester.getBottomLeft(find.text('3.Bb5')).dy, lessThanOrEqualTo(before.bottom));
    expect(tester.getBottomLeft(nextLine).dy, greaterThan(before.bottom));
    final engine = tester.getRect(find.byType(EnginePanel));
    await tester.timedDragFrom(
      Offset(engine.center.dx, engine.bottom + desktopEngineRightRailGutterThickness / 2),
      const Offset(0, 160),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(view).height, greaterThan(before.height));
    expect(nextLine.hitTestable(), findsOneWidget);
  });

  testWidgets('wide rails show both analyses without shrinking the board', (tester) async {
    await _pumpBoard(tester, size: const Size(2400, 820), toby: false);
    final before = _boardSize(tester);

    // Height-bound: the board takes every pixel the two player rows leave.
    final area = tester.getSize(_boardAreaFinder);
    final chrome = computeBoardAreaChromeMetrics(
      focusMode: false,
      hasPlayerInfo: true,
    );
    final available =
        area.height -
        2 * chrome.outerPadding -
        chrome.topRowHeight -
        chrome.bottomRowHeight -
        chrome.headerGapTotal;
    expect(before, moreOrLessEquals(available));

    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TobyViewTabs), findsNothing);
    expect(find.byType(WhatTobyThinks), findsOneWidget);
    expect(find.text('Stockfish'), findsOneWidget);
    expect(find.text('3.Nf3'), findsOneWidget);
    expect(_boardSize(tester), before);
    tester.view.physicalSize = const Size(1100, 1000);
    await tester.pumpAndSettle();
    expect(find.byType(TobyViewTabs), findsOneWidget);
    expect(find.byType(WhatTobyThinks), findsNothing);
  });

  testWidgets('on the Stockfish tab the board pane asks Toby nothing', (
    tester,
  ) async {
    final probe = await _pumpBoard(tester, toby: false);
    // Two positions back: White to move again, so the engine's Nc3 draws.
    for (var step = 0; step < 2; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    probe.emitEngine(_engineLine);
    await tester.pump();

    expect(find.byType(WhatTobyThinks), findsNothing);
    expect(_queries, isEmpty);
    // Stockfish's arrows are on the board.
    expect(_boardShapes(tester).whereType<cg.Arrow>(), isNotEmpty);
  });

  testWidgets('arrow source is independent of the visible tab and hover', (tester) async {
    final probe = await _pumpBoard(tester, toby: false);
    final prefs = ProviderScope.containerOf(tester.element(find.byType(BoardPane)))
        .read(boardAnalysisPreferencesProvider.notifier);
    probe.emitEngine(_engineLine);
    _drawCircle(tester, Square.e4);
    await tester.pump();
    final circle = _circleAt(tester, Square.e4);
    final engine = _engineArrow(tester);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await _tapTab(tester, kTobyFeatureLabel);
    expect(_boardShapes(tester), containsAll(<cg.Shape>[circle, engine]));

    prefs.setArrows(BoardAnalysisArrows.toby);
    await tester.pump();
    expect(_nonToby(tester), {circle});
    expect(_boardShapes(tester).where(_isToby).map(_tobyArrow), [
      (Square.d2, Square.d4), (Square.g1, Square.f3),
    ]);
    final shapes = _boardShapes(tester);
    final hover = await _hover(tester, find.text('3.Nf3'));
    expect(_boardShapes(tester), shapes);
    await hover.removePointer();

    await _tapTab(tester, 'Stockfish');
    await tester.pump();
    expect(_boardShapes(tester).where(_isToby), hasLength(2));
    prefs.setArrows(BoardAnalysisArrows.off);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_boardShapes(tester), {circle});
  });

  testWidgets('a pinned candidate with a class puts the '
      'report\'s mark on its square, as the board marks a report move; the '
      'top three carry colour only', (tester) async {
    await _pumpBoard(tester, arrows: BoardAnalysisArrows.toby);
    // After 1. e4 e5 2. Nf3 Nc6, from 50%: Bb5 the only good move.
    _script.value = TobyReadingState.ready(
      const TobyReading(
        isFinal: true,
        sideToMove: Side.white,
        candidates: [
          TobyCandidate(
            uci: 'f1b5',
            san: 'Bb5',
            probability: 0.6,
            wdl: TobyWdl(white: 0.40, draw: 0.30, black: 0.30),
          ),
          TobyCandidate(
            uci: 'h2h3',
            san: 'h3',
            probability: 0.3,
            wdl: TobyWdl(white: 0.15, draw: 0.30, black: 0.55),
          ),
        ],
        positionWdl: TobyWdl(white: 0.35, draw: 0.30, black: 0.35),
        otherProbability: 0.1,
        otherMoveCount: 12,
      ),
    );
    await tester.pump();
    await tester.pump();

    Finder mark(GameMoveClassification classification) =>
        find.byWidgetPredicate(
          (widget) =>
              widget is SvgPicture &&
              widget.bytesLoader is SvgAssetLoader &&
              (widget.bytesLoader as SvgAssetLoader).assetName ==
                  classificationIconAsset(classification),
        );
    final onBoard = find.descendant(
      of: find.byType(BoardWheelNavigation),
      matching: mark(GameMoveClassification.bestMove),
    );
    expect(_boardShapes(tester).where(_isToby), hasLength(2));
    expect(onBoard, findsNothing);

    final gesture = await _hover(tester, find.text('3.Bb5'));
    await tester.pumpAndSettle();
    expect(onBoard, findsNothing);
    await tester.tap(find.text('3.Bb5'));
    await tester.pumpAndSettle();
    expect(onBoard, findsOneWidget);
    // The report mark's placement: 40% of a square, centred on b5's
    // top-right corner (nudged 4% down).
    final board = tester.getRect(find.byType(DesktopChessBoard));
    final square = board.width / 8;
    final badge = tester.getRect(onBoard);
    // Inside the badge's 0.5 px lip.
    expect(badge.width, moreOrLessEquals(square * 0.40 - 1, epsilon: 0.01));
    expect(
      badge.center.dx,
      moreOrLessEquals(board.left + 2 * square, epsilon: 0.5),
    );
    expect(
      badge.center.dy,
      moreOrLessEquals(board.top + 3 * square + square * 0.04, epsilon: 0.5),
    );

    await gesture.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 400));
    expect(onBoard, findsOneWidget);
    expect(
      (_boardShapes(tester).where(_isToby).single as cg.Arrow).color.withValues(
        alpha: 1,
      ),
      classificationColor(GameMoveClassification.bestMove),
    );
  });

  testWidgets('a pin adds Toby\'s arrow beside the reader\'s shapes', (
    tester,
  ) async {
    final probe = await _pumpBoard(tester, arrows: BoardAnalysisArrows.toby);
    probe.emitEngine(_engineLine);
    _drawCircle(tester, Square.e4);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    await tester.pump();
    final circle = _circleAt(tester, Square.e4);

    final gesture = await _hover(tester, find.text('3.Nf3'));
    await tester.tap(find.text('3.Nf3'));
    await tester.pump();
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 400));

    final pinned = _boardShapes(tester);
    expect(pinned, contains(circle));
    expect(pinned.whereType<cg.Arrow>().where((a) => !_isToby(a)), isEmpty);
    expect(pinned.where(_isToby).map(_tobyArrow), [(Square.g1, Square.f3)]);
  });

  testWidgets('a pin resets when the position changes; ←/→ still step the '
      'game from the rows', (tester) async {
    await _pumpBoard(tester, arrows: BoardAnalysisArrows.toby);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.pump();
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    await tester.pump();
    final start = _boardFen(tester);

    await tester.tap(find.text('1.Nf3'));
    await tester.pump();
    expect(_boardShapes(tester).where(_isToby).map(_tobyArrow), [
      (Square.g1, Square.f3),
    ]);

    // Focus is on Toby's rows; → still steps the game.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    // The frame that moves the board still holds the old position's
    // arrows: the board draws none of them on the new position.
    expect(_boardFen(tester), isNot(start));
    expect(_boardShapes(tester).where(_isToby), isEmpty);
    await tester.pump();
    // The pin is gone; the new position's reading draws its top two.
    expect(_boardShapes(tester).where(_isToby), hasLength(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump();
    expect(_boardFen(tester), start);
    expect(_boardShapes(tester).where(_isToby), hasLength(2));
    // Drain the tooltip's deferred exit after the pointer target changed.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('each position visited on the Toby tab is asked about once', (
    tester,
  ) async {
    await _pumpBoard(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.pump();
    _queries.clear();
    _script.value = TobyReadingState.ready(_reading(final_: true));
    for (var step = 0; step < 3; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
    }
    expect(_queries.map((q) => q.request.moves.length).toList(), [1, 2, 3]);
  });

  testWidgets('Stockfish ticks and hovers rebuild neither Toby nor the board '
      'area', (tester) async {
    final probe = await _pumpBoard(tester);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    probe.emitEngine(_engineLine);
    await tester.pump();
    await tester.pump();

    final rebuilt = <String, int>{};
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, _) {
      final type = element.widget.runtimeType.toString();
      rebuilt.update(type, (count) => count + 1, ifAbsent: () => 1);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    for (var depth = 13; depth < 18; depth++) {
      for (final notifier in probe.notifiers) {
        notifier.emit(
          BoardEvalState(pvs: _engineLine, isEvaluating: true, depth: depth),
        );
      }
      await tester.pump();
    }
    expect(rebuilt['WhatTobyThinks'] ?? 0, 0);

    final gesture = await _hover(tester, find.text('3.d4'));
    await gesture.moveTo(tester.getCenter(find.text('3.Nf3')));
    await tester.pump();
    debugOnRebuildDirtyWidget = previous;
    expect(rebuilt['_BoardArea'] ?? 0, 0);
    expect(rebuilt['DesktopChessBoard'] ?? 0, 0);
    await gesture.removePointer();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the Toby tab sizes the engine pane for three whole rows; '
      'moving through the game never resizes it, and Stockfish keeps the '
      'split as it was', (tester) async {
    await _pumpBoard(tester, size: const Size(1100, 860), toby: false);
    double engineHeight() => tester.getSize(find.byType(EnginePanel)).height;
    final stockfish = engineHeight();
    expect(_engineComfortableSize(tester), isNull);

    _script.value = TobyReadingState.ready(_reading(final_: true));
    await _tapTab(tester, kTobyFeatureLabel);
    await tester.pump(const Duration(seconds: 1));
    final comfortable = _engineComfortableSize(tester);
    expect(comfortable, isNotNull);
    expect(comfortable, greaterThan(stockfish));
    // The rail has room: the pane takes it, and Toby's view gets exactly the
    // height of its reading line, three whole rows and the attribution.
    final toby = engineHeight();
    expect(toby, moreOrLessEquals(comfortable!));
    final view = tester.getSize(find.byType(WhatTobyThinks));
    expect(
      view.height,
      moreOrLessEquals(
        WhatTobyThinks.comfortableHeight(
          tester.element(find.byType(WhatTobyThinks)),
          width: view.width,
          compactPredictions: true,
        ),
      ),
    );

    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.home,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(engineHeight(), moreOrLessEquals(toby), reason: key.keyLabel);
      expect(_engineComfortableSize(tester), comfortable, reason: key.keyLabel);
    }

    await _tapTab(tester, TobyViewTabs.stockfishLabel);
    await tester.pump(const Duration(seconds: 1));
    expect(_engineComfortableSize(tester), isNull);
    expect(engineHeight(), moreOrLessEquals(stockfish));
  });

  testWidgets('on the Toby tab the engine pane follows the reader\'s drags '
      'and the window, as on Stockfish: a window change never undoes a '
      'drag', (tester) async {
    await _pumpBoard(tester, size: const Size(1100, 860), toby: false);
    double engineHeight() => tester.getSize(find.byType(EnginePanel)).height;
    Future<void> resize(double height) async {
      tester.view.physicalSize = Size(1100, height);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Stockfish's run, for the shape of the shrink.
    await resize(640);
    final stockfishAt640 = engineHeight();
    await resize(860);
    final stockfishAt860 = engineHeight();
    expect(stockfishAt640, lessThan(stockfishAt860));

    _script.value = TobyReadingState.ready(_reading(final_: true));
    await _tapTab(tester, kTobyFeatureLabel);
    await tester.pump(const Duration(seconds: 1));
    final grown = engineHeight();
    expect(grown, moreOrLessEquals(_engineComfortableSize(tester)!));

    // The window shrinks: so does the pane, in step with the split's
    // weights, never held at its comfortable height.
    await resize(640);
    final at640 = engineHeight();
    expect(at640, lessThan(grown - 1));
    await resize(560);
    final at560 = engineHeight();
    expect(at560, lessThan(at640));
    await resize(860);
    expect(engineHeight(), moreOrLessEquals(grown, epsilon: 1));

    // Drag the gutter under the engine pane up, then down.
    Future<void> drag(double dy) async {
      final engine = tester.getRect(find.byType(EnginePanel));
      await tester.timedDragFrom(
        Offset(
          engine.center.dx,
          engine.bottom + desktopEngineRightRailGutterThickness / 2,
        ),
        Offset(0, dy),
        const Duration(milliseconds: 200),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    await drag(-80);
    final shorter = engineHeight();
    expect(shorter, lessThan(grown - 40));
    // A window change of one pixel keeps the drag.
    await resize(859);
    expect(engineHeight(), moreOrLessEquals(shorter, epsilon: 1));
    await resize(820);
    expect(engineHeight(), lessThanOrEqualTo(shorter + 0.5));
    await resize(860);
    expect(engineHeight(), moreOrLessEquals(shorter, epsilon: 1));

    await drag(200);
    final taller = engineHeight();
    expect(taller, greaterThan(grown + 100));
    await resize(859);
    expect(engineHeight(), moreOrLessEquals(taller, epsilon: 1));

    // Nothing ever overflows or throws on the way.
    expect(tester.takeException(), isNull);

    // Back on Stockfish, the reader's last drag stays.
    await _tapTab(tester, TobyViewTabs.stockfishLabel);
    await tester.pump(const Duration(seconds: 1));
    expect(engineHeight(), moreOrLessEquals(taller, epsilon: 1));
  });

  testWidgets('the tabs replace the engine\'s name in the same header row: '
      'no extra height', (tester) async {
    await _pumpEnginePanel(tester, const Size(640, 560), toby: false);
    final withTabs = _pvLines(tester).first.top;
    expect(find.byType(TobyViewTabs), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpEnginePanel(
      tester,
      const Size(640, 560),
      toby: false,
      withToby: false,
    );
    expect(find.byType(TobyViewTabs), findsNothing);
    expect(find.text('Stockfish'), findsOneWidget);
    expect(_pvLines(tester).first.top, withTabs);
  });

  testWidgets('a pane shorter than the rail\'s least engine pane closes its '
      'header up; a Stockfish line the edge cuts dissolves, one barely on '
      'screen is covered', (tester) async {
    await _pumpEnginePanel(tester, const Size(640, 560), toby: false);
    final roomy = _pvLines(tester);
    expect(roomy, hasLength(3));
    final cutFade = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_CutItemFade',
    );
    List<(Rect, Paint)> fades() {
      final painted = <(Rect, Paint)>[];
      expect(
        tester.renderObject(cutFade),
        paints..everything((method, arguments) {
          if (method == #drawRect) {
            painted.add((arguments[0] as Rect, arguments[1] as Paint));
          }
          return true;
        }),
      );
      return painted;
    }

    expect(fades(), isEmpty);
    final gap = roomy[1].top - roomy[0].bottom;

    // The second line mostly on screen: it dissolves into the pane.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpEnginePanel(
      tester,
      Size(640, roomy[1].top + roomy[1].height * 0.85),
      toby: false,
    );
    expect(_pvLines(tester).first.top, roomy.first.top);
    expect(fades().single.$2.shader, isNotNull);

    // Under the rail's least engine pane (which only a rail too short for
    // every pane hands out), the header gives up 12 px of padding so the
    // first line stays whole; the second, with under three quarters of it
    // on screen, is covered whole: no glyph tops along the edge.
    const short = 110.0;
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpEnginePanel(tester, const Size(640, short), toby: false);
    final lines = _pvLines(tester);
    expect(lines.first.top, moreOrLessEquals(roomy.first.top - 12));
    expect(lines.first.bottom, lessThanOrEqualTo(short));
    final cover = fades().single;
    expect(cover.$2.shader, isNull);
    expect(
      cover.$1.height,
      moreOrLessEquals(short - (lines.first.bottom + gap)),
    );
  });

  testWidgets('Toby\'s rows line up with Stockfish\'s', (tester) async {
    // Scores of four figures, which fit the 56 px column on one line in the
    // test font (every glyph as wide as its size), as "+0.24" does in the
    // app's font.
    await _pumpEnginePanel(
      tester,
      const Size(640, 560),
      toby: false,
      lines: [
        for (final line in _threeLines)
          BoardPv(evaluation: 0, mate: null, moves: line.moves),
      ],
    );
    final pvRow = _pvLines(tester)[1];
    final score = tester.getTopLeft(
      find.descendant(of: _pvLineFinder.at(1), matching: find.text('0.00')),
    );
    final moves = tester.getTopLeft(
      find.descendant(
        of: _pvLineFinder.first,
        matching: find.textContaining('3.Bb5'),
      ),
    );

    await _tapTab(tester, kTobyFeatureLabel);
    await tester.pump();
    final rows = _tobyRows(tester);
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.height, pvRow.height);
      expect((row.left, row.right), (pvRow.left, pvRow.right));
    }
    expect(rows[1].top - rows[0].bottom, 6);
    expect(tester.getTopLeft(find.text('60.0%')).dx, score.dx);
    expect(tester.getTopLeft(find.text('Nf3')).dx, moves.dx);
    // Stockfish keeps analysing: its score stays in the header.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == '0.00' &&
            widget.style?.fontSize == 22,
      ),
      findsOneWidget,
    );
  });

  testWidgets('a narrow header keeps the tabs whole: the depth goes first, '
      'then the labels close up to keep the score, then the score goes; the '
      'lines under the header never move', (tester) async {
    await _pumpEnginePanel(tester, const Size(1000, 400), toby: false);
    final tabs = tester.getSize(find.byType(TobyViewTabs)).width;
    final compact = TobyViewTabs.widthOf(
      tester.element(find.byType(TobyViewTabs)),
      compact: true,
    );
    expect(compact, lessThan(tabs));
    final score = tester.getSize(_headerScore()).width;
    final depth = tester.getSize(find.text('d24')).width;
    final firstLine = _pvLines(tester).first.top;
    // What the header keeps around the middle: its padding, the gear and
    // the gap after it, and the power control with its gaps.
    final middle =
        tester
            .getRect(
              find
                  .ancestor(
                    of: find.byType(TobyViewTabs),
                    matching: find.byType(LayoutBuilder),
                  )
                  .first,
            )
            .width;
    final chrome = 1000 - middle;

    Future<void> at(double width) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpEnginePanel(tester, Size(width, 400), toby: false);
    }

    void tabsWhole(double width) {
      // On screen, after any scaling.
      expect(tester.getRect(find.byType(TobyViewTabs)).width, width);
      for (final label in ['Stockfish', kTobyFeatureLabel]) {
        final paragraph = tester.renderObject<RenderParagraph>(_tab(label));
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.getRect(_tab(label)).width, paragraph.size.width);
      }
      expect(_pvLines(tester).first.top, firstLine);
    }

    // Room for the tabs and the score, not the depth (whose chip is wider
    // than its label).
    await at(chrome + tabs + 8 + score + 8 + depth - 1);
    expect(find.text('d24'), findsNothing);
    expect(_headerScore(), findsOneWidget);
    tabsWhole(tabs);
    // Not for the tabs and the score: the labels close up, and the score
    // stays.
    await at(chrome + tabs + 8 + score - 1);
    expect(_headerScore(), findsOneWidget);
    tabsWhole(compact);
    // Not even for that: the score goes, the header keeps its height.
    await at(chrome + compact + 8 + score - 1);
    expect(find.text('d24'), findsNothing);
    expect(_headerScore(), findsNothing);
    tabsWhole(compact);
    // The controls stay.
    expect(find.byType(EngineSettingsPopover), findsOneWidget);
    expect(find.byIcon(Icons.power_settings_new_rounded), findsOneWidget);
  });

  testWidgets('with every control in the header, the labels keep 90% of '
      'their size or more down to the header\'s least width, and the board\'s '
      'right rail never goes narrower than that', (tester) async {
    await _pumpEnginePanel(
      tester,
      const Size(1000, 400),
      toby: false,
      chrome: true,
    );
    final least = EnginePanel.headerMinWidth(
      tester.element(find.byType(EnginePanel)),
      trailing: true,
      pictureInPicture: true,
    );

    double scaleOf(String label) {
      final paragraph = tester.renderObject<RenderParagraph>(_tab(label));
      expect(paragraph.didExceedMaxLines, isFalse);
      // On screen, after any scaling.
      return tester.getRect(_tab(label)).width / paragraph.size.width;
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpEnginePanel(
      tester,
      Size(least.ceilToDouble(), 400),
      toby: false,
      chrome: true,
    );
    for (final label in ['Stockfish', kTobyFeatureLabel]) {
      expect(scaleOf(label), greaterThanOrEqualTo(kEngineHeaderTabsMinScale));
      expect(scaleOf(label), lessThan(1));
    }
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsOneWidget);

    // The board holds its right rail to that width, for the controls its
    // engine header has.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpBoard(tester, toby: false);
    final panel = tester.widget<EnginePanel>(find.byType(EnginePanel));
    expect(panel.headerTrailing, isNotNull);
    final rail = tester
        .widget<ResizableSplitView>(
          find.byWidgetPredicate(
            (widget) =>
                widget is ResizableSplitView &&
                widget.children.any((child) => child.label == 'Analysis'),
          ),
        )
        .children
        .singleWhere((child) => child.label == 'Analysis');
    expect(
      rail.minSize,
      EnginePanel.headerMinWidth(
        tester.element(find.byType(EnginePanel)),
        trailing: true,
        pictureInPicture: panel.onPictureInPicture != null,
      ),
    );
    expect(rail.minSize, greaterThanOrEqualTo(280));
  });

  testWidgets('choosing a narrow tab by keyboard keeps the '
      'engine pane, the notation and the focus on the tab', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () =>
          FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic,
    );
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await _pumpBoard(tester, toby: false);
    final engine = tester.state(find.byType(EnginePanel));
    final notation = tester.state(find.byType(NotationOpeningPanel));
    final notationContent = tester.element(
      find.byWidgetPredicate(
        (widget) =>
            widget is KeyedSubtree &&
            widget.key is GlobalKey &&
            (widget.key! as GlobalKey).toString().contains('Notation'),
      ),
    );

    Future<void> press(String label, LogicalKeyboardKey key) async {
      final tab = Focus.of(tester.element(_tab(label)));
      tab.requestFocus();
      await tester.pump();
      expect(tab.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.state(find.byType(EnginePanel)), same(engine));
      expect(tester.state(find.byType(NotationOpeningPanel)), same(notation));
      expect(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is KeyedSubtree &&
                  widget.key is GlobalKey &&
                  (widget.key! as GlobalKey).toString().contains('Notation'),
            )
            .evaluate()
            .single,
        same(notationContent),
      );
      expect(tab.hasPrimaryFocus, isTrue);
    }

    await press(kTobyFeatureLabel, LogicalKeyboardKey.enter);
    expect(find.byType(WhatTobyThinks), findsOneWidget);
    expect(_notationPanel(tester).showEngine, isTrue);
    await press('Stockfish', LogicalKeyboardKey.space);
    expect(find.byType(WhatTobyThinks), findsNothing);
    expect(_notationPanel(tester).showEngine, isTrue);
  });

  testWidgets('when Stockfish lines are off, Toby fills the pane', (tester) async {
    await _pumpBoard(tester, toby: false, stockfish: false);
    expect(find.byType(TobyViewTabs), findsNothing);
    expect(_notationPanel(tester).showEngine, isTrue);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('3.Nf3'), findsOneWidget);
    expect(_queries, isNotEmpty);
  });

  testWidgets('with the report open, Toby takes the live-engine half of the '
      'split', (tester) async {
    await _pumpEnginePanel(
      tester,
      const Size(640, 700),
      toby: true,
      reportVisible: true,
    );
    final split = find.byWidgetPredicate(
      (widget) =>
          widget is ResizableSplitView &&
          widget.storageKey == desktopEngineReportSplitStorageKey,
    );
    expect(split, findsOneWidget);
    final view = tester.widget<ResizableSplitView>(split);
    expect(view.children.first.label, kTobyFeatureLabel);
    expect(
      find.descendant(of: split, matching: find.byType(WhatTobyThinks)),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.byType(WhatTobyThinks)).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(GameReportView)).top),
    );
  });

  testWidgets('with the report open, Toby\'s half grows toward its three '
      'whole rows from the report\'s share, down to the report\'s least', (
    tester,
  ) async {
    await _pumpEnginePanel(
      tester,
      const Size(640, 420),
      toby: true,
      reportVisible: true,
    );
    final split = find.byWidgetPredicate(
      (widget) =>
          widget is ResizableSplitView &&
          widget.storageKey == desktopEngineReportSplitStorageKey,
    );
    final view = tester.getSize(find.byType(WhatTobyThinks));
    final comfortable = WhatTobyThinks.comfortableHeight(
      tester.element(find.byType(WhatTobyThinks)),
      width: view.width,
    );
    expect(
      tester.widget<ResizableSplitView>(split).children.first.comfortableSize,
      moreOrLessEquals(comfortable),
    );
    // 40% of this split is short of the three rows: the report lends the
    // rest and keeps its 140 px least.
    expect(view.height, moreOrLessEquals(comfortable));
    expect(
      tester.getSize(find.byType(GameReportView)).height,
      greaterThanOrEqualTo(140),
    );

    // A drag on Toby's half holds through window changes: the split does
    // not grow it back to the three rows.
    final dragFrom = tester.getRect(find.byType(WhatTobyThinks));
    await tester.timedDragFrom(
      Offset(
        dragFrom.center.dx,
        dragFrom.bottom + desktopEngineReportGutterThickness / 2,
      ),
      const Offset(0, -30),
      const Duration(milliseconds: 200),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final dragged = tester.getSize(find.byType(WhatTobyThinks)).height;
    expect(dragged, lessThan(comfortable - 20));
    for (final height in [419.0, 400.0]) {
      tester.view.physicalSize = Size(640, height);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getSize(find.byType(WhatTobyThinks)).height,
        lessThanOrEqualTo(dragged + 0.5),
        reason: '$height',
      );
    }
    tester.view.physicalSize = const Size(640, 420);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getSize(find.byType(WhatTobyThinks)).height,
      moreOrLessEquals(dragged, epsilon: 1),
    );

    // Stockfish's half keeps the split's own share.
    await _tapTab(tester, TobyViewTabs.stockfishLabel);
    expect(
      tester.widget<ResizableSplitView>(split).children.first.comfortableSize,
      isNull,
    );
  });
}

final _boardAreaFinder = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_BoardArea',
);

/// Toby's answer for whatever position the board asks about.
final _script = ValueNotifier<TobyReadingState>(
  const TobyReadingState(TobyStatus.thinking),
);
final _queries = <TobyQuery>[];

class _ScriptedToby extends TobyReadingNotifier {
  @override
  TobyReadingState build(TobyQuery query) {
    _queries.add(query);
    void follow() => state = _script.value;
    _script.addListener(follow);
    ref.onDispose(() => _script.removeListener(follow));
    return _script.value;
  }
}

TobyReading _reading({required bool final_}) => TobyReading(
  isFinal: final_,
  sideToMove: Side.white,
  candidates: [
    TobyCandidate(
      uci: 'g1f3',
      san: 'Nf3',
      probability: 0.6,
      prior: 0.5,
      wdl: final_ ? const TobyWdl(white: 0.3, draw: 0.5, black: 0.2) : null,
    ),
    TobyCandidate(
      uci: 'd2d4',
      san: 'd4',
      probability: 0.3,
      wdl: final_ ? const TobyWdl(white: 0.32, draw: 0.5, black: 0.18) : null,
    ),
  ],
  positionWdl: const TobyWdl(white: 0.3, draw: 0.5, black: 0.2),
  otherProbability: 0.1,
  otherMoveCount: 12,
);

const List<BoardPv> _engineLine = <BoardPv>[
  BoardPv(evaluation: 0.25, mate: null, moves: 'b1c3 g8f6'),
];

double _boardSize(WidgetTester tester) =>
    tester.widget<DesktopChessBoard>(find.byType(DesktopChessBoard)).size;

String _boardFen(WidgetTester tester) =>
    tester.widget<DesktopChessBoard>(find.byType(DesktopChessBoard)).fen;

Set<cg.Shape> _boardShapes(WidgetTester tester) =>
    tester
        .widget<DesktopChessBoard>(find.byType(DesktopChessBoard))
        .shapes
        .toSet();

/// Toby's arrows, in any class's colour or Toby's teal.
bool _isToby(cg.Shape shape) =>
    shape is cg.Arrow &&
    <GameMoveClassification?>[
      null,
      ...GameMoveClassification.values,
    ].map(tobyArrowHue).contains(shape.color.withValues(alpha: 1));

/// Everything on the board but Toby's arrows.
Set<cg.Shape> _nonToby(WidgetTester tester) =>
    _boardShapes(tester).where((shape) => !_isToby(shape)).toSet();

(Square, Square) _tobyArrow(cg.Shape shape) {
  expect(_isToby(shape), isTrue, reason: '$shape is not Toby\'s arrow');
  final arrow = shape as cg.Arrow;
  return (arrow.orig, arrow.dest);
}

cg.Arrow _engineArrow(WidgetTester tester) => _boardShapes(
  tester,
).whereType<cg.Arrow>().singleWhere((arrow) => arrow.orig == Square.b1);

cg.Circle _circleAt(WidgetTester tester, Square square) => _boardShapes(
  tester,
).whereType<cg.Circle>().singleWhere((circle) => circle.orig == square);

void _drawCircle(WidgetTester tester, Square square) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(BoardPane)),
  );
  final fen = _boardFen(tester).split(' ').take(4).join(' ');
  container
      .read(boardAnnotationsProvider('tournaments-default').notifier)
      .toggleCircle(square, AnnotationColor.green, positionKey: fen);
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(TobyViewTabs), matching: find.text(label));

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(_tab(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

/// The header's score readout (not a Stockfish line's score).
Finder _headerScore() => find.byWidgetPredicate(
  (widget) =>
      widget is Text && widget.data == '+0.31' && widget.style?.fontSize == 22,
);

NotationOpeningPanel _notationPanel(WidgetTester tester) =>
    tester.widget<NotationOpeningPanel>(find.byType(NotationOpeningPanel));

/// Toby's rows, by their painted surface.
List<Rect> _tobyRows(WidgetTester tester) => [
  for (final element
      in find
          .byWidgetPredicate(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == '_TobyRowPainter',
          )
          .evaluate())
    tester.getRect(find.byElementPredicate((e) => e == element)),
];

double? _engineComfortableSize(WidgetTester tester) {
  final split = tester.widget<ResizableSplitView>(
    find.byWidgetPredicate(
      (widget) =>
          widget is ResizableSplitView &&
          widget.storageKey == desktopEngineRightRailSplitStorageKey,
    ),
  );
  return split.children.first.comfortableSize;
}

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(location: const Offset(5, 5));
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
  return gesture;
}

const String _pgn = '''
[Event "Probe"]
[White "White"]
[Black "Black"]
[WhiteElo "2650"]
[BlackElo "2610"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 *
''';

const BoardTabGameArgs _args = BoardTabGameArgs(
  gameId: 'toby-probe-game',
  pgn: _pgn,
  label: 'White - Black',
  whiteName: 'White',
  blackName: 'Black',
  tournamentTitle: 'Probe event',
  gameListSelectedId: 'toby-probe-game',
);

class _BoardProbe {
  const _BoardProbe(this._notifiers);

  final Map<String, _ManualBoardEvalNotifier> _notifiers;

  Iterable<_ManualBoardEvalNotifier> get notifiers =>
      _notifiers.values.where((notifier) => notifier.mounted);

  void emitEngine(List<BoardPv> pvs, {bool isEvaluating = true}) {
    for (final notifier in _notifiers.values) {
      if (notifier.mounted) {
        notifier.emit(BoardEvalState(pvs: pvs, isEvaluating: isEvaluating, depth: 12));
      }
    }
  }
}

Future<_BoardProbe> _pumpBoard(
  WidgetTester tester, {
  Size size = const Size(1100, 1000),
  bool toby = true,
  BoardAnalysisArrows arrows = BoardAnalysisArrows.stockfish,
  bool? stockfish,
}) async {
  SharedPreferences.setMockInitialValues({
    tobyTabStorageKey: toby,
    'desktop.analysis.arrows.v1': arrows.name,
    if (stockfish != null) 'desktop.analysis.stockfish.v1': stockfish,
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast();
  final railUpdates = StreamController<Map<String, LiveGameUpdate>>.broadcast();
  addTearDown(activeUpdates.close);
  addTearDown(railUpdates.close);
  final evalNotifiers = <String, _ManualBoardEvalNotifier>{};

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardTabGameArgsByTabIdProvider.overrideWith(
          (ref) => <String, BoardTabGameArgs>{'tournaments-default': _args},
        ),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        engineSettingsProviderNew.overrideWith(_EngineWithArrowsOnNotifier.new),
        desktopTabsProvider.overrideWith((ref) => DesktopTabsNotifier()),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
        boardEvalProvider.overrideWith((ref, fen) {
          final cached = evalNotifiers[fen];
          if (cached != null && cached.mounted) return cached;
          return evalNotifiers[fen] = _ManualBoardEvalNotifier(ref, fen);
        }),
        gameUpdatesStreamProvider.overrideWith(
          (ref, gameId) => activeUpdates.stream,
        ),
        gameUpdatesBatchStreamProvider.overrideWith(
          (ref, key) => railUpdates.stream,
        ),
        subscriptionProvider.overrideWith(
          (ref) => SubscriptionNotifier.stub(
            SubscriptionState(
              isSubscribed: true,
              expirationDate: DateTime.now().add(const Duration(days: 30)),
            ),
          ),
        ),
        desktopEntitlementProvider.overrideWithValue(
          const DesktopEntitlementSnapshot(accountId: 'reader', generation: 1),
        ),
        tobyReadingProvider.overrideWith(_ScriptedToby.new),
      ],
      child: const MaterialApp(
        home: Scaffold(body: BoardPane(tabId: 'tournaments-default')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();

  expect(find.byType(DesktopChessBoard), findsOneWidget);
  return _BoardProbe(evalNotifiers);
}

class _ManualBoardEvalNotifier extends BoardEvalNotifier {
  _ManualBoardEvalNotifier(Ref ref, String fen)
    : super(
        ref,
        fen,
        const BoardEvalConfig(
          enabled: false,
          searchTimeIndex: 0,
          principalVariationIndex: 0,
        ),
      );

  void emit(BoardEvalState value) => state = value;
}

class _TestAutoPinPreferences extends AutoPinPreferencesNotifier {
  @override
  Future<AutoPinPreferences> build() async => AutoPinPreferences.defaults;
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(soundEnabled: false, showEvaluationBar: false);
}

class _EngineWithArrowsOnNotifier extends EngineSettingsNotifierNew {
  EngineSettings get _settings => EngineSettings(
    showEngineGauge: false,
    showTobyBar: _tobyBar,
    showEngineAnalysis: _engineOn,
    showPvArrows: true,
    principalVariationIndex: _pvIndex,
    maxArrowsOnBoard: 0,
  );

  @override
  Future<EngineSettings> build() async => _settings;

  @override
  Future<void> toggleEngineAnalysis(bool value) async {
    state = AsyncValue.data(_settings.copyWith(showEngineAnalysis: value));
  }

}

class _TestKeyboardShortcutsNotifier extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async {
    return BoardShortcutMap(defaultBoardShortcuts());
  }
}

int _pvIndex = 0;
bool _engineOn = true;

/// The Toby bar beside the board. Off for the tests of the Toby Predicts
/// tab alone (on its own the tab asks only while it is shown); on for the
/// bar's own tests.
bool _tobyBar = false;

const List<BoardPv> _threeLines = <BoardPv>[
  BoardPv(evaluation: 0.31, mate: null, moves: 'f1b5 a7a6 b5a4 g8f6 e1g1'),
  BoardPv(evaluation: 0.24, mate: null, moves: 'd2d4 e5d4 f3d4 g8f6 d4c6'),
  BoardPv(evaluation: 0.18, mate: null, moves: 'f1c4 f8c5 c2c3 g8f6 d2d4'),
];

final _pvLineFinder = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_PvLine',
);

List<Rect> _pvLines(WidgetTester tester) => [
  for (final element in _pvLineFinder.evaluate())
    tester.getRect(find.byElementPredicate((e) => e == element)),
];

/// The engine pane alone, [size] logical pixels, with three Stockfish lines;
/// on the Toby tab when [toby], and with the header's tabs unless
/// [withToby] is false.
Future<void> _pumpEnginePanel(
  WidgetTester tester,
  Size size, {
  required bool toby,
  bool withToby = true,
  bool reportVisible = false,
  bool chrome = false,
  List<BoardPv> lines = _threeLines,
}) async {
  SharedPreferences.setMockInitialValues({tobyTabStorageKey: toby});
  _pvIndex = 2;
  _script.value = TobyReadingState.ready(_reading(final_: true));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  const fen =
      'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';
  final controller = TobyPanelController(session: 'engine-pane-0001');
  addTearDown(controller.dispose);
  final report = GameAnalysisReportController();
  addTearDown(report.dispose);
  final notifiers = <String, _ManualBoardEvalNotifier>{};
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subscriptionProvider.overrideWith(
          (ref) => SubscriptionNotifier.stub(
            SubscriptionState(
              isSubscribed: true,
              expirationDate: DateTime.now().add(const Duration(days: 30)),
            ),
          ),
        ),
        desktopEntitlementProvider.overrideWithValue(
          const DesktopEntitlementSnapshot(accountId: 'reader', generation: 1),
        ),
        tobyReadingProvider.overrideWith(_ScriptedToby.new),
        engineSettingsProviderNew.overrideWith(_EngineWithArrowsOnNotifier.new),
        boardEvalProvider.overrideWith(
          (ref, fen) => notifiers[fen] = _ManualBoardEvalNotifier(ref, fen),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder:
                (context, ref, _) => EnginePanel(
                  fen: fen,
                  sideToMove: 'w',
                  reportController: report,
                  onPlayUci: (_) {},
                  pvSanFormatter: (input) async => formatEnginePvSanLine(input),
                  reportVisible: reportVisible,
                  // The board's more-actions button and a live game's
                  // picture-in-picture control.
                  headerTrailing:
                      chrome
                          ? const Icon(Icons.more_vert_rounded, size: 16)
                          : null,
                  onPictureInPicture: chrome ? () {} : null,
                  toby:
                      withToby
                          ? WhatTobyThinks(
                            target: TobyTarget.read(
                              TobyRequest(
                                moves: const ['e2e4', 'e7e5', 'g1f3', 'b8c6'],
                              ),
                              positionKey: fen,
                            ),
                            controller: controller,
                          )
                          : null,
                  tobyTabSelected: ref.watch(tobyTabSelectedProvider),
                ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  notifiers[fen]!.emit(
    BoardEvalState(pvs: lines, isEvaluating: true, depth: 24),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 121));
  await tester.pump();
}
