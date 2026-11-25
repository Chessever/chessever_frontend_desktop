import 'dart:async';
import 'dart:io';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/engine/pv_san_formatter.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/toby/what_toby_thinks.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';

/// The whole board pane with the "What Toby Thinks" panel in its engine
/// pane: what reaches the board, and what the rail reserves.
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
  });

  testWidgets('the board keeps its full height: nothing is reserved under it, '
      'and opening Toby does not resize it', (tester) async {
    await _pumpBoard(tester, size: const Size(2400, 820), open: false);
    final collapsed = _boardSize(tester);

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
    expect(collapsed, moreOrLessEquals(available));

    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.tap(find.text(kTobyFeatureLabel));
    await tester.pump();
    await tester.pump();
    expect(_boardSize(tester), collapsed);
    // The split slides to Toby's new size; nothing under the board moves.
    await tester.pump(const Duration(seconds: 1));
    expect(tester.getSize(find.byType(WhatTobyThinks)).height, 210);
    expect(_boardSize(tester), collapsed);
  });

  testWidgets('hovering a candidate leaves only its arrow on the board', (
    tester,
  ) async {
    final probe = await _pumpBoard(tester);
    probe.emitEngine(_engineLine);
    _drawCircle(tester, Square.e4);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    await tester.pump();

    final circle = _circleAt(tester, Square.e4);
    final engine = _engineArrow(tester);
    expect(_boardShapes(tester), containsAll(<cg.Shape>[circle, engine]));

    final gesture = await _hover(tester, find.text('d4'));
    final hover = _boardShapes(tester);
    expect(hover, hasLength(1));
    expect(_tobyArrow(hover.single), (Square.d2, Square.d4));

    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(_boardShapes(tester), containsAll(<cg.Shape>[circle, engine]));
  });

  testWidgets('a pin hides the engine arrows but keeps the reader\'s shapes', (
    tester,
  ) async {
    final probe = await _pumpBoard(tester);
    probe.emitEngine(_engineLine);
    _drawCircle(tester, Square.e4);
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    await tester.pump();
    final circle = _circleAt(tester, Square.e4);
    final engine = _engineArrow(tester);

    final gesture = await _hover(tester, find.text('Nf3'));
    await tester.tap(find.text('Nf3'));
    await tester.pump();
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();

    final pinned = _boardShapes(tester);
    expect(pinned, contains(circle));
    expect(pinned, isNot(contains(engine)));
    expect(pinned.where(_isToby).map(_tobyArrow), [(Square.g1, Square.f3)]);
  });

  testWidgets('a pin resets when the position changes', (tester) async {
    await _pumpBoard(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.pump();
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    await tester.pump();
    final start = _boardFen(tester);

    await tester.tap(find.text('Nf3'));
    await tester.pump();
    expect(_boardShapes(tester).where(_isToby), hasLength(1));

    // Focus is on Toby's rows; → still steps the game.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    expect(_boardFen(tester), isNot(start));
    expect(_boardShapes(tester).where(_isToby), isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump();
    expect(_boardFen(tester), start);
    expect(_boardShapes(tester).where(_isToby), isEmpty);
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

    final gesture = await _hover(tester, find.text('d4'));
    await gesture.moveTo(tester.getCenter(find.text('Nf3')));
    await tester.pump();
    debugOnRebuildDirtyWidget = previous;
    expect(rebuilt['_BoardArea'] ?? 0, 0);
    expect(rebuilt['DesktopChessBoard'], greaterThan(0));
  });

  testWidgets('the engine pane\'s comfortable size holds through every stage '
      'and every move', (tester) async {
    await _pumpBoard(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.pump();

    final sizes = <double?>[];
    final heights = <double>[];
    void record() {
      sizes.add(_engineComfortableSize(tester));
      heights.add(tester.getSize(find.byType(WhatTobyThinks)).height);
    }

    _queries.clear();
    record();
    _script.value = TobyReadingState(
      TobyStatus.network,
      reading: _reading(final_: false),
    );
    await tester.pump();
    record();
    _script.value = TobyReadingState.ready(_reading(final_: true));
    await tester.pump();
    record();
    for (var step = 0; step < 3; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
      record();
    }

    expect(sizes.toSet(), {
      desktopEnginePaneComfortableSize(
        lines: 1,
        tobyHeight: kTobyPanelExpandedHeight,
      ),
    });
    expect(heights.toSet(), {kTobyPanelExpandedHeight});
    // Each position visited is asked about once, with its own moves.
    expect(_queries.map((q) => q.request.moves.length).toList(), [1, 2, 3]);
  });

  testWidgets('Toby sits directly under the last Stockfish line; room left '
      'over goes below it', (tester) async {
    await _pumpEnginePanel(tester, const Size(360, 560));

    final lines = _pvLines(tester);
    expect(lines, hasLength(3));
    final toby = tester.getRect(find.byType(WhatTobyThinks));
    // The list's own 12 px bottom padding, then Toby.
    expect(toby.top, lines.last.bottom + 12);
    expect(toby.height, kTobyPanelExpandedHeight);
    expect(toby.bottom, lessThan(560));
  });

  testWidgets('a short engine pane gives Toby three slots before it takes a '
      'Stockfish line out of view', (tester) async {
    await _pumpEnginePanel(tester, const Size(360, 330));

    final toby = tester.getRect(find.byType(WhatTobyThinks));
    expect(toby.height, tobyPanelHeight(expanded: true, slots: 3));
    // The lines keep room for two rows and end where Toby starts.
    final lines = tester.getRect(_pvListFinder);
    expect(lines.bottom, toby.top);
    expect(lines.height, greaterThanOrEqualTo(desktopEngineLinesHeight(2)));

    // With room for two lines and the full panel, all five slots come back.
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpEnginePanel(
      tester,
      Size(
        360,
        desktopEngineHeaderHeight +
            desktopEngineLinesHeight(2) +
            kTobyPanelExpandedHeight,
      ),
    );
    expect(
      tester.getSize(find.byType(WhatTobyThinks)).height,
      kTobyPanelExpandedHeight,
    );
  });

  testWidgets('Toby lines up with the Stockfish rows', (tester) async {
    await _pumpEnginePanel(tester, const Size(360, 560));

    final row = _pvLineFinder.at(1);
    final score = find.descendant(of: row, matching: find.text('+0.24'));
    expect(
      tester.getTopLeft(find.text(kTobyFeatureLabel)).dx,
      tester.getTopLeft(score).dx,
    );
    expect(tester.getTopLeft(find.text('Nf3')).dx, tester.getTopLeft(score).dx);
    final moves = find.descendant(
      of: _pvLineFinder.first,
      matching: find.textContaining('3.Bb5'),
    );
    final bar = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_ProbabilityPainter',
    );
    // The moves open with a move number whose figure sits 1 px inside the
    // text's box; the bars start at the figure, not 1 px ahead of it.
    expect(tester.getTopLeft(bar.first).dx, tester.getTopLeft(moves).dx + 1);
    final pvChevron = tester.getRect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
    );
    final tobyChevron = tester.getRect(
      find.descendant(
        of: find.byType(WhatTobyThinks),
        matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
      ),
    );
    expect(
      (tobyChevron.left, tobyChevron.right),
      (pvChevron.left, pvChevron.right),
    );
  });

  testWidgets('the rail grows the engine pane for up to three Stockfish lines '
      'above the full panel', (tester) async {
    _pvIndex = 2;
    await _pumpBoard(tester, size: const Size(1440, 860));
    await tester.pump(const Duration(seconds: 1));

    expect(
      _engineComfortableSize(tester),
      desktopEngineHeaderHeight +
          desktopEngineLinesHeight(3) +
          kTobyPanelExpandedHeight,
    );
    expect(
      tester.getSize(find.byType(EnginePanel)).height,
      _engineComfortableSize(tester),
    );
    expect(
      tester.getSize(find.byType(WhatTobyThinks)).height,
      kTobyPanelExpandedHeight,
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

bool _isToby(cg.Shape shape) =>
    shape is cg.Arrow && shape.color == kTobyArrowColor;

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

  void emitEngine(List<BoardPv> pvs) {
    for (final notifier in _notifiers.values) {
      if (notifier.mounted) {
        notifier.emit(BoardEvalState(pvs: pvs, isEvaluating: true, depth: 12));
      }
    }
  }
}

Future<_BoardProbe> _pumpBoard(
  WidgetTester tester, {
  Size size = const Size(1800, 1000),
  bool open = true,
}) async {
  SharedPreferences.setMockInitialValues({tobyPanelOpenStorageKey: open});
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
  expect(find.byType(WhatTobyThinks), findsOneWidget);
  expect(
    tester.getSize(find.byType(WhatTobyThinks)).height,
    open ? kTobyPanelExpandedHeight : kTobyPanelCollapsedHeight,
  );
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

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(soundEnabled: false, showEvaluationBar: false);
}

class _EngineWithArrowsOnNotifier extends EngineSettingsNotifierNew {
  EngineSettings get _settings => EngineSettings(
    showEngineGauge: false,
    showEngineAnalysis: true,
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

const List<BoardPv> _threeLines = <BoardPv>[
  BoardPv(evaluation: 0.31, mate: null, moves: 'f1b5 a7a6 b5a4 g8f6 e1g1'),
  BoardPv(evaluation: 0.24, mate: null, moves: 'd2d4 e5d4 f3d4 g8f6 d4c6'),
  BoardPv(evaluation: 0.18, mate: null, moves: 'f1c4 f8c5 c2c3 g8f6 d2d4'),
];

final _pvLineFinder = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_PvLine',
);

final _pvListFinder = find.descendant(
  of: find.byType(EnginePanel),
  matching: find.byType(ListView),
);

List<Rect> _pvLines(WidgetTester tester) => [
  for (final element in _pvLineFinder.evaluate())
    tester.getRect(find.byElementPredicate((e) => e == element)),
];

/// The engine pane alone, [size] tall, with three Stockfish lines and Toby
/// expanded under them.
Future<void> _pumpEnginePanel(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({tobyPanelOpenStorageKey: true});
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
                  toby: WhatTobyThinks(
                    target: TobyTarget.read(
                      TobyRequest(
                        moves: const ['e2e4', 'e7e5', 'g1f3', 'b8c6'],
                      ),
                      positionKey: fen,
                    ),
                    controller: controller,
                  ),
                  tobyExpanded: ref.watch(tobyPanelExpandedProvider),
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
    const BoardEvalState(pvs: _threeLines, isEvaluating: true, depth: 24),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 121));
  await tester.pump();
}
