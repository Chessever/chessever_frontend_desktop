import 'dart:async';

import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/desktop/widgets/desktop_opening_explorer.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:dartchess/dartchess.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _initialFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  testWidgets('renders position search results as a table', (tester) async {
    final repository = _FakeGamebaseRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 360,
              height: 520,
              child: DesktopPositionGamesTable(
                fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('WHITE'), findsOneWidget);
    expect(find.text('BLACK'), findsOneWidget);
    expect(find.text('RES'), findsOneWidget);
    expect(find.text('YEAR'), findsOneWidget);
    expect(find.text('Carlsen'), findsOneWidget);
    expect(find.text('Nakamura'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == '1–0',
      ),
      findsOneWidget,
    );
    expect(find.text('2025'), findsOneWidget);
    expect(find.text('NOTATION'), findsNothing);
    expect(find.text('1.e4'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>(
          'position-game-notation-token-games-gamebase-1-0',
        ),
      ),
      findsOneWidget,
    );
    expect(
      _horizontalScrollableCountIn(
        tester,
        find.byType(DesktopPositionGamesTable),
      ),
      1,
    );
    expect(find.text('10.d4'), findsOneWidget);
    expect(find.byType(MoveHoverPreview), findsWidgets);
    expect(find.text('A29'), findsOneWidget);
    expect(find.text('English Opening'), findsOneWidget);
    expect(find.text('Four Knights'), findsOneWidget);
    expect(find.text('Freestyle Chess'), findsOneWidget);
    expect(find.text('Reykjavik'), findsOneWidget);
    expect(find.text('RPD'), findsOneWidget);
    expect(find.text('ONL'), findsOneWidget);
  });

  testWidgets('reference layout uses reference-style games column order', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 1200,
              height: 520,
              child: DesktopPositionGamesTable(
                fen: _initialFen,
                referenceLayout: true,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    final orderedHeaders = [
      'WHITE',
      'ELO W',
      'BLACK',
      'ELO B',
      'RES',
      'YEAR',
      'EVENT',
      'NOTATION',
      'ECO',
    ];
    final lefts = [
      for (final header in orderedHeaders)
        tester.getTopLeft(find.text(header)).dx,
    ];
    for (var i = 1; i < lefts.length; i++) {
      expect(lefts[i], greaterThan(lefts[i - 1]));
    }
  });

  testWidgets('standalone games layout keeps metadata before long notation', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 2200,
              height: 520,
              child: DesktopPositionGamesTable(fen: _initialFen),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    final orderedHeaders = [
      'WHITE',
      'ELO W',
      'BLACK',
      'ELO B',
      'RES',
      'YEAR',
      'EVENT',
      'OPENING',
    ];
    final lefts = [
      for (final header in orderedHeaders)
        tester.getTopLeft(find.text(header)).dx,
    ];
    for (var i = 1; i < lefts.length; i++) {
      expect(lefts[i], greaterThan(lefts[i - 1]));
    }
    expect(find.text('NOTATION'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Freestyle Chess')).dy,
      lessThan(tester.getTopLeft(find.text('1.e4')).dy),
    );
  });

  testWidgets('pauses position game queries while inactive', (tester) async {
    final repository = _FakeGamebaseRepository();
    var active = false;
    StateSetter? setHarnessState;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: StatefulBuilder(
              builder: (context, setState) {
                setHarnessState = setState;
                return SizedBox(
                  width: 360,
                  height: 520,
                  child: DesktopPositionGamesTable(
                    fen: _initialFen,
                    active: active,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();
    expect(repository.positionGameCalls, isEmpty);

    setHarnessState!(() => active = true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(repository.positionGameCalls, hasLength(1));
    expect(find.text('Carlsen'), findsOneWidget);

    setHarnessState!(() => active = false);
    await tester.pump();
    setHarnessState!(() => active = true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(repository.positionGameCalls, hasLength(1));
  });

  testWidgets(
    'keeps previous rows visible while refreshing the next position',
    (tester) async {
      final repository = _DeferredGamebaseRepository();
      var fen = _initialFen;
      StateSetter? setHarnessState;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gamebaseRepositoryProvider.overrideWithValue(repository),
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: StatefulBuilder(
                builder: (context, setState) {
                  setHarnessState = setState;
                  return SizedBox(
                    width: 720,
                    height: 520,
                    child: DesktopPositionGamesTable(fen: fen),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(repository.requests, hasLength(1));
      repository.requests.single.complete(
        _singlePositionGamesResponse(
          id: 'gamebase-old',
          white: 'Carlsen',
          black: 'Nakamura',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Carlsen'), findsOneWidget);

      final afterE4 = Chess.initial.play(NormalMove.fromUci('e2e4')).fen;
      setHarnessState!(() => fen = afterE4);
      await tester.pump();

      expect(repository.requests, hasLength(2));
      expect(find.text('Carlsen'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      repository.requests.last.complete(
        _singlePositionGamesResponse(
          id: 'gamebase-new',
          white: 'Kasparov',
          black: 'Kramnik',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Carlsen'), findsNothing);
      expect(find.text('Kasparov'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  testWidgets('right-click shows context menu without opening game tab', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 360,
              height: 520,
              child: DesktopPositionGamesTable(fen: _initialFen),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.text('Carlsen')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Open game in new tab'), findsOneWidget);
    expect(find.text('Insert game'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopPositionGamesTable)),
    );
    expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
  });

  testWidgets('double-tapping the player-name area opens the game tab', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 360,
              height: 520,
              child: DesktopPositionGamesTable(
                fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carlsen'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('Carlsen'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopPositionGamesTable)),
    );
    final argsByTab = container.read(boardTabGameArgsByTabIdProvider);

    expect(argsByTab, hasLength(1));
    final args = argsByTab.values.single;
    expect(args.gameId, 'gamebase-1');
    expect(args.whiteName, 'Carlsen');
    expect(args.blackName, 'Nakamura');
  });

  testWidgets('opened position game carries continuation title and query', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();
    final afterE4 = Chess.initial.play(NormalMove.fromUci('e2e4')).fen;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 360,
              height: 520,
              child: DesktopPositionGamesTable(
                fen: afterE4,
                moves: const ['e2e4'],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carlsen'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('Carlsen'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopPositionGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;

    expect(args.databaseTitle, 'Continuation after 1.e4');
    expect(args.databaseTitle, isNot('Gamebase Database'));
    expect(args.databaseGamesPagination, isNotNull);
    expect(args.databaseGamesPagination!.query.moves, const ['e2e4']);
    expect(args.databaseGamesPagination!.nextPageNumber, 1);
  });

  testWidgets('applies explorer filters and OpenAPI sort fields to queries', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 360,
              height: 520,
              child: DesktopPositionGamesTable(
                fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopPositionGamesTable)),
    );
    container
        .read(gamebaseExplorerProvider.notifier)
        .updateFilters(
          const GamebaseFilters(
            timeControls: [TimeControl.rapid],
            minRating: 2400,
            maxRating: 2900,
            yearFrom: 2000,
            yearTo: 2024,
            isOnline: true,
            sortBy: GamebaseSortField.site,
            sortDirection: GamebaseSortDirection.asc,
          ),
        );
    await tester.pumpAndSettle();

    final query = repository.positionGameCalls.last;
    expect(query.timeControl, TimeControl.rapid);
    expect(query.minRating, 2400);
    expect(query.maxRating, 2900);
    expect(query.yearFrom, 2000);
    expect(query.yearTo, 2024);
    expect(query.isOnline, isTrue);
    expect(query.sortBy, GamebaseSortField.site);
    expect(query.sortDirection, GamebaseSortDirection.asc);
    expect(query.notationPlies, 16);
  });

  testWidgets('mouse hover stays passive and click selects the games table', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository(rowCount: 20);
    final controller = DesktopPositionGamesTableController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: SizedBox(
              width: 720,
              height: 160,
              child: AnimatedBuilder(
                animation: controller,
                builder:
                    (context, _) => DesktopPositionGamesTable(
                      fen:
                          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
                      controller: controller,
                    ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();
    final verticalScrollable = _verticalScrollableIn(
      tester,
      find.byType(DesktopPositionGamesTable),
    );
    verticalScrollable.position.jumpTo(0);
    await tester.pump();
    expect(find.text('White0'), findsOneWidget);

    final beforeHover = verticalScrollable.position.pixels;
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('White0'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(verticalScrollable.position.pixels, closeTo(beforeHover, 0.01));
    expect(controller.selectedRowId, isNull);

    await tester.tap(find.text('White0'));
    await tester.pump();
    expect(controller.selectedRowId, 'gamebase-0');
  });

  testWidgets('mouse hover does not scroll the opening move table', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();
    int? focusedMoveIndex;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repository),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: StatefulBuilder(
              builder:
                  (context, setState) => SizedBox(
                    width: 360,
                    height: 180,
                    child: DesktopOpeningExplorer(
                      onMove: (_) {},
                      focusedMoveIndex: focusedMoveIndex,
                      onFocusMoveIndex:
                          (index) => setState(() => focusedMoveIndex = index),
                      compactColumns: true,
                      showHeader: false,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopOpeningExplorer)),
    );
    container.read(gamebaseExplorerProvider.notifier).setPosition(_initialFen);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    final verticalScrollable = _verticalScrollableIn(
      tester,
      find.byType(DesktopOpeningExplorer),
    );
    verticalScrollable.position.jumpTo(120);
    await tester.pump();

    final beforeHover = verticalScrollable.position.pixels;
    final target =
        tester.getTopLeft(find.byType(DesktopOpeningExplorer)) +
        const Offset(48, 126);
    final pointer = TestPointer(2, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(target));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(focusedMoveIndex, isNotNull);
    expect(verticalScrollable.position.pixels, closeTo(beforeHover, 0.01));
  });
}

ScrollableState _verticalScrollableIn(WidgetTester tester, Finder ancestor) {
  final scrollables = find.descendant(
    of: ancestor,
    matching: find.byType(Scrollable),
  );
  for (final element in scrollables.evaluate()) {
    final state = tester.state<ScrollableState>(
      find.byElementPredicate((candidate) => candidate == element),
    );
    final direction = state.position.axisDirection;
    if (direction == AxisDirection.down || direction == AxisDirection.up) {
      return state;
    }
  }
  throw StateError('No vertical Scrollable found.');
}

int _horizontalScrollableCountIn(WidgetTester tester, Finder ancestor) {
  final scrollables = find.descendant(
    of: ancestor,
    matching: find.byType(Scrollable),
  );
  var count = 0;
  for (final element in scrollables.evaluate()) {
    final state = tester.state<ScrollableState>(
      find.byElementPredicate((candidate) => candidate == element),
    );
    final direction = state.position.axisDirection;
    if (direction == AxisDirection.right || direction == AxisDirection.left) {
      count++;
    }
  }
  return count;
}

const _spanishContinuation = <String>[
  'e2e4',
  'e7e5',
  'g1f3',
  'b8c6',
  'f1b5',
  'a7a6',
  'b5a4',
  'g8f6',
  'e1g1',
  'f8e7',
  'f1e1',
  'b7b5',
  'a4b3',
  'd7d6',
  'c2c3',
  'e8g8',
  'h2h3',
  'c8b7',
  'd2d4',
  'e5d4',
];

const _legalFirstMoves = <String>[
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

class _FakeGamebaseRepository extends GamebaseRepository {
  _FakeGamebaseRepository({this.rowCount = 1})
    : super(Dio(), baseUrl: 'http://localhost');

  final int rowCount;
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
    return GamebaseResponse(
      status: 'success',
      data: GamebaseData(
        moves: [
          for (final (i, uci) in _legalFirstMoves.indexed)
            MoveAggregate(
              uci: uci,
              white: 38 + i,
              black: 24,
              draws: 38,
              total: 90 + i,
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
    positionGameCalls.add(
      _CapturedPositionGamesQuery(
        timeControl: timeControl,
        minRating: minRating,
        maxRating: maxRating,
        yearFrom: yearFrom,
        yearTo: yearTo,
        isOnline: isOnline,
        sortBy: sortBy,
        sortDirection: sortDirection,
        notationPlies: notationPlies,
      ),
    );
    final continuation =
        fen.contains('/4P3/')
            ? _spanishContinuation.sublist(1)
            : _spanishContinuation;
    return GamebaseSearchQueryResponse(
      status: 'success',
      data: [
        for (var i = 0; i < rowCount; i++)
          {
            'id': rowCount == 1 ? 'gamebase-1' : 'gamebase-$i',
            'white': rowCount == 1 ? 'Carlsen' : 'White$i',
            'black': rowCount == 1 ? 'Nakamura' : 'Black$i',
            'whiteFed': 'NOR',
            'blackFed': 'USA',
            'whiteTitle': 'GM',
            'blackTitle': 'GM',
            'whiteElo': 2830 - i,
            'blackElo': 2780 + i,
            'result': i.isEven ? '1-0' : '0-1',
            'date': '2025-02-${(14 + i % 10).toString().padLeft(2, '0')}',
            'event': 'Freestyle Chess',
            'site': 'Reykjavik',
            'timeControl': 'RAPID',
            'isOnline': true,
            'opening': 'English Opening',
            'variation': 'Four Knights',
            'eco': 'A29',
            'continuation': continuation,
          },
      ],
      metadata: GamebasePaginationMetadata(
        pageNumber: pageNumber,
        pageSize: pageSize,
        hasMoreValue: false,
      ),
    );
  }
}

class _DeferredGamebaseRepository extends GamebaseRepository {
  _DeferredGamebaseRepository() : super(Dio(), baseUrl: 'http://localhost');

  final List<_DeferredPositionGamesRequest> requests =
      <_DeferredPositionGamesRequest>[];

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
  }) {
    final request = _DeferredPositionGamesRequest();
    requests.add(request);
    return request.future;
  }
}

class _DeferredPositionGamesRequest {
  final Completer<GamebaseSearchQueryResponse> _completer =
      Completer<GamebaseSearchQueryResponse>();

  Future<GamebaseSearchQueryResponse> get future => _completer.future;

  void complete(GamebaseSearchQueryResponse response) {
    _completer.complete(response);
  }
}

GamebaseSearchQueryResponse _singlePositionGamesResponse({
  required String id,
  required String white,
  required String black,
}) {
  return GamebaseSearchQueryResponse(
    status: 'success',
    data: [
      {
        'id': id,
        'white': white,
        'black': black,
        'whiteFed': 'NOR',
        'blackFed': 'USA',
        'whiteTitle': 'GM',
        'blackTitle': 'GM',
        'whiteElo': 2830,
        'blackElo': 2780,
        'result': '1-0',
        'date': '2025-02-14',
        'event': 'Freestyle Chess',
        'site': 'Reykjavik',
        'timeControl': 'RAPID',
        'isOnline': true,
        'opening': 'English Opening',
        'variation': 'Four Knights',
        'eco': 'A29',
        'continuation': _spanishContinuation,
      },
    ],
    metadata: const GamebasePaginationMetadata(
      pageNumber: 0,
      pageSize: 25,
      hasMoreValue: false,
    ),
  );
}

class _CapturedPositionGamesQuery {
  const _CapturedPositionGamesQuery({
    this.timeControl,
    this.minRating,
    this.maxRating,
    this.yearFrom,
    this.yearTo,
    this.isOnline,
    this.sortBy,
    this.sortDirection,
    this.notationPlies,
  });

  final TimeControl? timeControl;
  final int? minRating;
  final int? maxRating;
  final int? yearFrom;
  final int? yearTo;
  final bool? isOnline;
  final GamebaseSortField? sortBy;
  final GamebaseSortDirection? sortDirection;
  final int? notationPlies;
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(useFigurine: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}
