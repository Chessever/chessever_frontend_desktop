import 'dart:async';
import 'dart:io';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory databaseDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'chessever-board-engine-surface-',
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

  testWidgets('depth-only engine tick does not rebuild the board surface', (
    tester,
  ) async {
    final probe = await _pumpBoardProbe(tester);
    probe.notifier.emit(_evalState(_initialPvs, depth: 10));
    await tester.pump();
    await tester.pump();

    final boardBoundaryFinder = find.descendant(
      of: find.byType(DesktopChessBoard),
      matching: find.byType(RepaintBoundary),
    );
    expect(boardBoundaryFinder, findsWidgets);
    final boardBoundary = tester.renderObject<RenderObject>(
      boardBoundaryFinder.first,
    );

    final rebuiltTypes = <String, int>{};
    var boardBoundaryPaints = 0;
    final previousRebuildCallback = debugOnRebuildDirtyWidget;
    final previousPaintCallback = debugOnProfilePaint;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final type = element.widget.runtimeType.toString();
      rebuiltTypes.update(type, (count) => count + 1, ifAbsent: () => 1);
    };
    debugOnProfilePaint = (renderObject) {
      if (identical(renderObject, boardBoundary)) boardBoundaryPaints++;
    };
    addTearDown(() {
      debugOnRebuildDirtyWidget = previousRebuildCallback;
      debugOnProfilePaint = previousPaintCallback;
    });

    // The score and PV list are the exact same immutable objects. Only the
    // engine panel's depth readout needs this update; no board-owned visual
    // input changed.
    probe.notifier.emit(_evalState(_initialPvs, depth: 11));
    await tester.pump();
    await tester.pump();

    final observed = (
      boardAreaBuilds: rebuiltTypes['_BoardArea'] ?? 0,
      annotationBuilds: rebuiltTypes['_BoardWithAnnotations'] ?? 0,
      chessboardBuilds: rebuiltTypes['DesktopChessBoard'] ?? 0,
      boardPaints: boardBoundaryPaints,
    );
    debugOnRebuildDirtyWidget = previousRebuildCallback;
    debugOnProfilePaint = previousPaintCallback;

    expect(
      observed,
      (
        boardAreaBuilds: 0,
        annotationBuilds: 0,
        chessboardBuilds: 0,
        boardPaints: 0,
      ),
      reason:
          'Depth/isEvaluating belong to the engine panel. The board should '
          'only subscribe to its score/PV projection.',
    );
  });

  testWidgets(
    'deep PV churn with stable arrows does not rebuild the board surface',
    (tester) async {
      final probe = await _pumpBoardProbe(tester);
      probe.notifier.emit(_evalState(_initialPvs, depth: 10));
      await tester.pump();
      await tester.pump();

      final boardBoundaryFinder = find.descendant(
        of: find.byType(DesktopChessBoard),
        matching: find.byType(RepaintBoundary),
      );
      expect(boardBoundaryFinder, findsWidgets);
      final boardBoundary = tester.renderObject<RenderObject>(
        boardBoundaryFinder.first,
      );

      final rebuiltTypes = <String, int>{};
      var boardBoundaryPaints = 0;
      final previousRebuildCallback = debugOnRebuildDirtyWidget;
      final previousPaintCallback = debugOnProfilePaint;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final type = element.widget.runtimeType.toString();
        rebuiltTypes.update(type, (count) => count + 1, ifAbsent: () => 1);
      };
      debugOnProfilePaint = (renderObject) {
        if (identical(renderObject, boardBoundary)) boardBoundaryPaints++;
      };
      addTearDown(() {
        debugOnRebuildDirtyWidget = previousRebuildCallback;
        debugOnProfilePaint = previousPaintCallback;
      });

      // Stockfish regularly refines the continuation while keeping the same
      // candidate move. Only the first UCI move is drawn on the board, so this
      // update belongs to the engine-lines pane and must not wake chessground.
      probe.notifier.emit(
        _evalState(const <BoardPv>[
          BoardPv(
            evaluation: 0.25,
            mate: null,
            moves: 'b1c3 d7d5 e2e4 g8f6 f1d3',
          ),
        ], depth: 11),
      );
      await tester.pump();
      await tester.pump();

      final arrow = _singleEngineArrow(tester);
      final observed = (
        boardAreaBuilds: rebuiltTypes['_BoardArea'] ?? 0,
        annotationBuilds: rebuiltTypes['_BoardWithAnnotations'] ?? 0,
        chessboardBuilds: rebuiltTypes['DesktopChessBoard'] ?? 0,
        boardPaints: boardBoundaryPaints,
        enginePanelBuilds: rebuiltTypes['EnginePanel'] ?? 0,
      );
      debugOnRebuildDirtyWidget = previousRebuildCallback;
      debugOnProfilePaint = previousPaintCallback;

      expect(
        (orig: arrow.orig, dest: arrow.dest),
        (orig: Square.b1, dest: Square.c3),
      );
      expect(
        observed,
        (
          boardAreaBuilds: 0,
          annotationBuilds: 0,
          chessboardBuilds: 0,
          boardPaints: 0,
          enginePanelBuilds: 0,
        ),
        reason:
            'Deep engine-line refinements do not change any board pixel. '
            'Rebuilds: $rebuiltTypes',
      );
    },
  );

  testWidgets('a changed first PV move still updates the board arrow', (
    tester,
  ) async {
    final probe = await _pumpBoardProbe(tester);

    probe.notifier.emit(_evalState(_initialPvs, depth: 10));
    await tester.pump();
    await tester.pump();
    final initialArrow = _singleEngineArrow(tester);
    expect(
      (orig: initialArrow.orig, dest: initialArrow.dest),
      (orig: Square.b1, dest: Square.c3),
    );

    probe.notifier.emit(_evalState(_changedPvs, depth: 11));
    await tester.pump();
    await tester.pump();
    final changedArrow = _singleEngineArrow(tester);
    expect(
      (orig: changedArrow.orig, dest: changedArrow.dest),
      (orig: Square.e2, dest: Square.e4),
    );
  });

  testWidgets('centipawn and mate ticks rebuild only the eval-bar leaf', (
    tester,
  ) async {
    final probe = await _pumpBoardProbe(tester, showGauge: true);

    probe.notifier.emit(
      const BoardEvalState(
        pvs: <BoardPv>[
          BoardPv(evaluation: 0.80, mate: null, moves: 'b1c3 g8f6'),
        ],
        isEvaluating: true,
        depth: 10,
      ),
    );
    await tester.pump();
    await tester.pump();
    var bar = tester.widget<DesktopEvalBar>(find.byType(DesktopEvalBar));
    expect(bar.evaluation, 0.80);
    expect(bar.mate, isNull);

    final rebuiltTypes = <String, int>{};
    final previousRebuildCallback = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final type = element.widget.runtimeType.toString();
      rebuiltTypes.update(type, (count) => count + 1, ifAbsent: () => 1);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousRebuildCallback);

    // The first PV move is intentionally unchanged. Only its score changes
    // from centipawns to mate, so arrows, pieces, and board layout stay put.
    probe.notifier.emit(
      const BoardEvalState(
        pvs: <BoardPv>[BoardPv(evaluation: 10, mate: 3, moves: 'b1c3 g8f6')],
        isEvaluating: true,
        depth: 11,
      ),
    );
    await tester.pump();
    await tester.pump();

    bar = tester.widget<DesktopEvalBar>(find.byType(DesktopEvalBar));
    expect(bar.evaluation, 10);
    expect(bar.mate, 3);
    expect(rebuiltTypes['_BoardEvalBarSurface'] ?? 0, greaterThan(0));
    expect(rebuiltTypes['_BoardArea'] ?? 0, 0);
    expect(rebuiltTypes['_BoardWithAnnotations'] ?? 0, 0);
    expect(rebuiltTypes['DesktopChessBoard'] ?? 0, 0);

    debugOnRebuildDirtyWidget = previousRebuildCallback;
  });

  testWidgets('a hidden Board tab installs no live engine evaluation', (
    tester,
  ) async {
    final probe = await _pumpBoardProbe(
      tester,
      showGauge: true,
      foreground: false,
    );

    expect(probe.notifierCount, 0);
    expect(find.byType(DesktopEvalBar), findsOneWidget);
    final bar = tester.widget<DesktopEvalBar>(find.byType(DesktopEvalBar));
    expect(bar.evaluation, isNull);
    expect(bar.mate, isNull);
    expect(bar.isEvaluating, isFalse);
  });
}

const String _pgn = '''
[Event "Probe"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''';

const BoardTabGameArgs _args = BoardTabGameArgs(
  gameId: 'probe-game',
  pgn: _pgn,
  label: 'White - Black',
  whiteName: 'White',
  blackName: 'Black',
  tournamentTitle: 'Probe event',
  gameListSelectedId: 'probe-game',
);

const List<BoardPv> _initialPvs = <BoardPv>[
  BoardPv(evaluation: 0.25, mate: null, moves: 'b1c3 g8f6'),
];

const List<BoardPv> _changedPvs = <BoardPv>[
  BoardPv(evaluation: 0.25, mate: null, moves: 'e2e4 e7e5'),
];

BoardEvalState _evalState(List<BoardPv> pvs, {required int depth}) =>
    BoardEvalState(pvs: pvs, isEvaluating: true, depth: depth);

cg.Arrow _singleEngineArrow(WidgetTester tester) {
  final board = tester.widget<DesktopChessBoard>(
    find.byType(DesktopChessBoard),
  );
  return board.shapes.whereType<cg.Arrow>().single;
}

Future<_BoardProbe> _pumpBoardProbe(
  WidgetTester tester, {
  bool showGauge = false,
  bool foreground = true,
}) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1800, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast();
  final railUpdates = StreamController<Map<String, LiveGameUpdate>>.broadcast();
  addTearDown(activeUpdates.close);
  addTearDown(railUpdates.close);
  final evalNotifiers = <String, _ManualBoardEvalNotifier>{};
  final tabsNotifier = DesktopTabsNotifier();
  if (!foreground) {
    tabsNotifier.open(TabKind.library, title: 'Library', reuseExisting: false);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardTabGameArgsByTabIdProvider.overrideWith(
          (ref) => const <String, BoardTabGameArgs>{
            'tournaments-default': _args,
          },
        ),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        engineSettingsProviderNew.overrideWith(
          () => _EngineWithArrowsOnNotifier(showGauge: showGauge),
        ),
        desktopTabsProvider.overrideWith((ref) => tabsNotifier),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
        boardEvalProvider.overrideWith((ref, fen) {
          return evalNotifiers.putIfAbsent(
            fen,
            () => _ManualBoardEvalNotifier(ref, fen),
          );
        }),
        gameUpdatesStreamProvider.overrideWith(
          (ref, gameId) => activeUpdates.stream,
        ),
        gameUpdatesBatchStreamProvider.overrideWith(
          (ref, key) => railUpdates.stream,
        ),
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
  expect(evalNotifiers, hasLength(foreground ? 1 : 0));
  return _BoardProbe(evalNotifiers);
}

class _BoardProbe {
  const _BoardProbe(this._notifiers);

  final Map<String, _ManualBoardEvalNotifier> _notifiers;

  int get notifierCount => _notifiers.length;
  _ManualBoardEvalNotifier get notifier => _notifiers.values.single;
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
  _EngineWithArrowsOnNotifier({required this.showGauge});

  final bool showGauge;

  EngineSettings get _settings => EngineSettings(
    showEngineGauge: showGauge,
    showEngineAnalysis: true,
    showPvArrows: true,
    autoGameAnalysis: false,
    principalVariationIndex: 0,
    maxArrowsOnBoard: 0,
  );

  @override
  Future<EngineSettings> build() async => _settings;

  @override
  Future<void> toggleEngineAnalysis(bool value) async {
    // ResizableSplitView may invoke its restore callback while establishing
    // test layout. Keep that callback deterministic and avoid loading the real
    // persisted defaults, which are outside this test's concern.
    state = AsyncValue.data(_settings.copyWith(showEngineAnalysis: value));
  }
}

class _TestKeyboardShortcutsNotifier extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async {
    return BoardShortcutMap(defaultBoardShortcuts());
  }
}
