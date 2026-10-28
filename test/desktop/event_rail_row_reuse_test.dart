import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/utils/date_time_provider.dart';

/// Rail row-reuse contract.
///
/// Mirrors the web rail, which reaches the same guarantees with
/// `memo(RoundGameRowImpl, railRowEqual)` plus handlers held in refs
/// (`RoundGamesList.tsx:396-409`, `RoundGameRow.tsx:294-312`): a row is only
/// rebuilt when its OWN content changed, the items carry stable content keys
/// (`getItemKey`, `RoundGamesList.tsx:359`), off-screen entries are never
/// constructed (`content-visibility: auto`, `components.css:4588`), and a
/// live round must not move the reader's viewport
/// (`overflow-anchor: none`, `components.css:1534-1541`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory databaseDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'chessever-rail-reuse-',
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

  /// One Olympiad-sized round: 600 boards, all ongoing, all in one round.
  List<TournamentGameSummary> olympiadRound({int count = 600}) {
    final moveTime = DateTime.utc(2026, 9, 19, 14);
    return <TournamentGameSummary>[
      for (var index = 0; index < count; index++)
        _board(index, moveTime.subtract(Duration(seconds: index))),
    ];
  }

  BoardTabGameArgs argsFor(
    List<TournamentGameSummary> games, {
    required String selectedId,
  }) {
    return BoardTabGameArgs(
      gameId: selectedId,
      pgn: _livePgn,
      label: 'Board 1',
      whiteName: games.first.whitePlayer,
      blackName: games.first.blackPlayer,
      tournamentTitle: 'FIDE Chess Olympiad 2026',
      fenSeed: _liveFen,
      viewSource: ChessboardView.forYou,
      eventGames: games,
      gameListSelectedId: selectedId,
    );
  }

  Future<ProviderContainer> pumpRail(
    WidgetTester tester, {
    required String tabId,
    required BoardTabGameArgs args,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{tabId: args},
          ),
          gameStreamRepositoryProvider.overrideWithValue(
            _SilentGameStreamRepository(),
          ),
          gameUpdatesBatchArrivalStreamProvider.overrideWith(
            (ref, key) => const Stream<
              LiveStreamArrival<Map<String, LiveGameUpdate>>
            >.empty(),
          ),
          dateTimeProvider.overrideWith(
            (ref) => Stream<DateTime>.value(DateTime.utc(2026, 9, 19, 14)),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: EventGamesTable.width,
              height: 700,
              child: EventGamesTable(tabId: tabId),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
  }

  List<Widget> railChunkWidgets(WidgetTester tester) {
    return tester
        .widgetList(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_EventRoundTable',
          ),
        )
        .toList(growable: false);
  }

  List<Widget> railEntryWidgets(WidgetTester tester) {
    return tester
        .widgetList(
          find.byWidgetPredicate((widget) {
            final key = widget.key;
            return key is ValueKey<String> && key.value.startsWith('rail-');
          }),
        )
        .toList(growable: false);
  }

  testWidgets('an unchanged rail rebuild reuses every mounted row chunk', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const tabId = 'rail-reuse';
    final games = olympiadRound();
    final container = await pumpRail(
      tester,
      tabId: tabId,
      args: argsFor(games, selectedId: games.first.id),
    );

    final before = railChunkWidgets(tester);
    expect(before, isNotEmpty);

    // A handler/args refresh that changes nothing about the rows — the shape of
    // a live tick that republishes board args. Web's `railRowEqual` answers
    // "nothing changed" for it; the rail must answer the same by handing the
    // SAME widget instance back, because a rebuilt chunk re-runs its
    // intrinsic-width table layout.
    container.read(boardTabGameArgsByTabIdProvider.notifier).update((byTab) {
      final current = byTab[tabId]!;
      return <String, BoardTabGameArgs>{
        ...byTab,
        tabId: current.copyWith(tournamentTitle: current.tournamentTitle),
      };
    });
    await tester.pump();

    final after = railChunkWidgets(tester);
    expect(after.length, before.length);
    for (var index = 0; index < before.length; index++) {
      expect(
        identical(before[index], after[index]),
        isTrue,
        reason:
            'Chunk $index was rebuilt although its content is unchanged. Only '
            'rows whose own data changed may be rebuilt.',
      );
    }
  });

  testWidgets('a changed row invalidates its own chunk and nothing else', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const tabId = 'rail-invalidate';
    final games = olympiadRound();
    final container = await pumpRail(
      tester,
      tabId: tabId,
      args: argsFor(games, selectedId: games.first.id),
    );

    final before = railChunkWidgets(tester);
    expect(before, isNotEmpty);

    // Replace ONE summary with a new instance carrying a newer clock: exactly
    // what a 5s safety refresh does to the rows it re-read.
    final refreshed = games.toList(growable: false);
    refreshed[1] = games[1].copyWith(
      whiteClockSeconds: 1234,
      lastMoveTime: DateTime.utc(2026, 9, 19, 14, 30),
    );
    container.read(boardTabGameArgsByTabIdProvider.notifier).update((byTab) {
      final current = byTab[tabId]!;
      return <String, BoardTabGameArgs>{
        ...byTab,
        tabId: current.copyWith(eventGames: refreshed),
      };
    });
    await tester.pump();

    final after = railChunkWidgets(tester);
    expect(after.length, before.length);
    expect(
      identical(before.first, after.first),
      isFalse,
      reason: 'The chunk holding the changed row must be rebuilt.',
    );
    for (var index = 1; index < before.length; index++) {
      expect(
        identical(before[index], after[index]),
        isTrue,
        reason: 'Untouched chunk $index must survive a single-row refresh.',
      );
    }
  });

  testWidgets('rail entries carry one stable content key each', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const tabId = 'rail-keys';
    final games = olympiadRound(count: 120);
    final container = await pumpRail(
      tester,
      tabId: tabId,
      args: argsFor(games, selectedId: games.first.id),
    );

    // Keys are content-derived, not positional (web `getItemKey`).
    expect(
      find.byKey(const ValueKey<String>('rail-header-round-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('rail-chunk-round-1-0')),
      findsOneWidget,
    );

    final keys = railEntryWidgets(tester)
        .map((widget) => (widget.key! as ValueKey<String>).value)
        .toList(growable: false);
    expect(keys.toSet().length, keys.length, reason: 'Duplicate rail keys.');

    // Same content, same keys: a rebuild may not renumber the list.
    container.read(boardTabGameArgsByTabIdProvider.notifier).update((byTab) {
      final current = byTab[tabId]!;
      return <String, BoardTabGameArgs>{
        ...byTab,
        tabId: current.copyWith(tournamentTitle: current.tournamentTitle),
      };
    });
    await tester.pump();
    final keysAfter = railEntryWidgets(tester)
        .map((widget) => (widget.key! as ValueKey<String>).value)
        .toList(growable: false);
    expect(keysAfter, keys);
  });

  testWidgets('off-screen rail entries are never constructed', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const tabId = 'rail-lazy';
    final games = olympiadRound();
    // Selecting board 500 widens the rail's rendered window to ~512 rows, i.e.
    // ~21 off-screen row chunks plus their round pieces.
    eventRailEntryBuilds = 0;
    await pumpRail(
      tester,
      tabId: tabId,
      args: argsFor(games, selectedId: games[499].id),
    );

    expect(
      eventRailEntryBuilds,
      lessThanOrEqualTo(16),
      reason:
          'A rebuild may only construct the entries its viewport mounts; a '
          '600-board round must not build every row chunk up front.',
    );
  });

  testWidgets('a streaming identity change keeps the reader where they were', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const tabId = 'rail-scroll';
    final games = olympiadRound();
    final container = await pumpRail(
      tester,
      tabId: tabId,
      args: argsFor(games, selectedId: games.first.id),
    );

    final scrollable = find
        .descendant(
          of: find.byType(EventGamesTable),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));

    position.jumpTo(300);
    await tester.pump();
    expect(position.pixels, 300);

    // Pausing the live stream swaps the list's identity (the same key flip the
    // backgrounded/minimised app performs). Chrome would hold the scroll position
    // through this with `overflow-anchor: none`; the rail must hold it too
    // instead of throwing the reader back to the top of the round.
    container.read(shouldStreamProvider.notifier).state = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      300,
      reason: 'The rail must keep its scroll position across a stream toggle.',
    );
  });
}

const String _livePgn = '''
[Event "FIDE Chess Olympiad 2026"]
[White "White 1"]
[Black "Black 1"]
[Result "*"]

1. e4 e5 *
''';

const String _liveFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

TournamentGameSummary _board(int index, DateTime lastMoveTime) {
  final board = index + 1;
  return TournamentGameSummary(
    id: 'olympiad-board-$board',
    name: 'Team A $board vs Team B $board',
    whitePlayer: 'White $board',
    blackPlayer: 'Black $board',
    hasPgn: true,
    pgn: _livePgn,
    fen: _liveFen,
    tourId: 'fide-olympiad-2026',
    tourSlug: 'fide-olympiad-2026',
    roundId: 'round-1',
    roundSlug: 'round-1',
    roundLabel: 'R1',
    roundName: 'Round 1',
    boardNumber: board,
    status: GameStatus.ongoing,
    hasStarted: true,
    lastMoveTime: lastMoveTime,
    roundStartsAt: DateTime.utc(2026, 9, 19, 13),
    whiteTeam: 'Team A $board',
    blackTeam: 'Team B $board',
  );
}

/// Keeps the rail off the network: no batch channel, no per-round channel.
class _SilentGameStreamRepository extends GameStreamRepository {
  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) {
    return const Stream<Map<String, LiveGameUpdate>>.empty();
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) {
    return const Stream<Map<String, LiveGameUpdate>>.empty();
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) {
    return const Stream<Map<String, LiveGameUpdate>>.empty();
  }
}
