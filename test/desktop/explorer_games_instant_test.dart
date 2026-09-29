import 'dart:async';

import 'package:chessever/desktop/services/gamebase_position_games_loader.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/widgets/desktop_opening_explorer.dart';
import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/explorer_games_cache.dart';
import 'package:chessever/screens/gamebase/providers/explorer_games_prefetch.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:dartchess/dartchess.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'support/desktop_premium_test_overrides.dart';

/// The desktop explorer's games table paints what the explorer already holds
/// in the frame a position lands, and never lets rows from another moment
/// (the previous position, a saved copy) pass for the current answer.

final String _startFen = Chess.initial.fen;

Position _play(List<String> ucis) {
  Position position = Chess.initial;
  for (final uci in ucis) {
    position = position.play(Move.parse(uci)!);
  }
  return position;
}

final String _e4Fen = _play(['e2e4']).fen;

String _label(List<String> moves) => moves.isEmpty ? 'start' : moves.last;

GamebaseSearchQueryResponse _page(String label, {int count = 3}) =>
    GamebaseSearchQueryResponse(
      status: 'success',
      data: [
        for (var i = 0; i < count; i++)
          {
            'id': '$label-$i',
            'white': '${label}W$i',
            'black': '${label}B$i',
            'whiteElo': 2700,
            'blackElo': 2650,
            'result': '1-0',
            'date': '2024-05-12',
            'event': 'Test Open',
          },
      ],
      metadata: const GamebasePaginationMetadata(
        pageNumber: 0,
        pageSize: 25,
        hasMoreValue: false,
      ),
    );

class _Request {
  _Request(this.fen, this.moves, this.uci, this.pageNumber);

  final String fen;
  final List<String> moves;
  final String? uci;
  final int pageNumber;
  final Completer<GamebaseSearchQueryResponse> completer =
      Completer<GamebaseSearchQueryResponse>();

  String get label => _label(moves);

  void answer([String? label, int count = 3]) =>
      completer.complete(_page(label ?? this.label, count: count));

  void fail() => completer.completeError(Exception('backend down'));
}

/// Games requests wait for the test unless [autoAnswer] is set; each answer
/// names the position it was asked for (its line's last move).
class _Repo extends GamebaseRepository {
  _Repo({this.autoAnswer = false}) : super(Dio(), baseUrl: 'http://localhost');

  bool autoAnswer;
  bool failNext = false;
  final List<_Request> requests = <_Request>[];
  int aggregateCalls = 0;
  List<MoveAggregate> aggregates = const <MoveAggregate>[];

  /// Answer every position with its first legal moves instead of
  /// [aggregates], so each position's rows lead somewhere real.
  bool legalAggregates = false;

  /// Requests still waiting for an answer.
  List<_Request> get pending =>
      requests.where((r) => !r.completer.isCompleted).toList();

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
    aggregateCalls += 1;
    return GamebaseResponse(
      status: 'success',
      data: GamebaseData(
        moves: legalAggregates ? _legalAggregates(fen) : aggregates,
      ),
    );
  }

  static List<MoveAggregate> _legalAggregates(String fen) {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final ucis = <String>[
      for (final entry in position.legalMoves.entries)
        for (final to in entry.value.squares)
          NormalMove(from: entry.key, to: to).uci,
    ];
    return [
      for (final (i, uci) in ucis.take(8).indexed)
        MoveAggregate(
          uci: uci,
          white: 10,
          black: 10,
          draws: 10,
          total: 900 - i * 100,
        ),
    ];
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
  }) {
    final request = _Request(fen, List.of(moves), uci, pageNumber);
    requests.add(request);
    if (failNext) {
      failNext = false;
      request.fail();
    } else if (autoAnswer) {
      request.answer();
    }
    return request.completer.future;
  }
}

/// A disk that already holds saved pages, keyed like the real one.
class _SavedDisk implements ExplorerGamesDiskStore {
  final Map<String, ExplorerGamesSnapshot> pages =
      <String, ExplorerGamesSnapshot>{};

  @override
  Future<Map<String, ExplorerGamesSnapshot>> readMany(
    List<String> keys, {
    required String owner,
  }) async => {
    for (final key in keys)
      if (pages[key] != null) key: pages[key]!,
  };

  @override
  Future<void> write(
    String key,
    GamebaseSearchQueryResponse response,
    DateTime fetchedAt, {
    required String owner,
  }) async {}

  @override
  Future<void> clear() async => pages.clear();
}

/// A saved disk whose reads wait for [release], like a disk queue busy
/// saving other pages.
class _SlowDisk extends _SavedDisk {
  final Completer<void> _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<Map<String, ExplorerGamesSnapshot>> readMany(
    List<String> keys, {
    required String owner,
  }) async {
    await _gate.future;
    return super.readMany(keys, owner: owner);
  }
}

/// The cache key the games table's page 0 at [fen] is saved under.
String _savedKey(_Repo repo, String fen, {List<String> moves = const []}) =>
    ExplorerGamesCache(repository: () => repo, currentUserId: () => '').keyFor(
      GamebasePositionGamesQuery.desktopTablePage(
        fen: fen,
        moves: moves,
        filters: const GamebaseFilters(),
      ),
    );

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(useFigurine: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

/// The table at a position the test moves with [_TableHarness.go].
class _TableHarness {
  _TableHarness(this.repo, {this.disk, this.now});

  final _Repo repo;
  final ExplorerGamesDiskStore? disk;

  /// The explorer games cache's clock, when the test moves time itself.
  final DateTime Function()? now;
  String fen = _startFen;
  List<String> moves = const <String>[];
  StateSetter? _setState;

  Widget build() => ProviderScope(
    overrides: [
      ...desktopPremiumTestOverrides,
      gamebaseRepositoryProvider.overrideWithValue(repo),
      boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
      explorerGamesWarmUpsEnabledProvider.overrideWithValue(true),
      if (disk != null) explorerGamesDiskStoreProvider.overrideWithValue(disk!),
      if (now != null)
        explorerGamesCacheProvider.overrideWith((ref) {
          final cache = ExplorerGamesCache(
            repository: () => repo,
            disk: disk ?? const NoopExplorerGamesDiskStore(),
            currentUserId: () => '',
            now: now,
          );
          ref.onDispose(cache.dispose);
          return cache;
        }),
    ],
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: kBackgroundColor,
        body: StatefulBuilder(
          builder: (context, setState) {
            _setState = setState;
            return SizedBox(
              width: 720,
              height: 520,
              child: DesktopPositionGamesTable(fen: fen, moves: moves),
            );
          },
        ),
      ),
    ),
  );

  void go(List<String> line) {
    _setState!(() {
      moves = List<String>.unmodifiable(line);
      fen = _play(line).fen;
    });
  }

  ProviderContainer container(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(DesktopPositionGamesTable)),
  );
}

Finder get _progressLine => find.byType(LinearProgressIndicator);

Future<void> _doubleClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  group('games table', () {
    testWidgets('a warmed position paints in the frame it lands, with no '
        'request', (tester) async {
      final repo = _Repo(autoAnswer: true);
      final harness = _TableHarness(repo);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();
      expect(find.text('startW0'), findsOneWidget);

      // The moves table warmed 1.e4 while the reader looked at it.
      final container = harness.container(tester);
      container
          .read(explorerGamesPrefetchProvider)
          .warmNow(
            desktopExplorerChildGamesQuery(
              fen: _startFen,
              moves: const [],
              uci: 'e2e4',
              filters: const GamebaseFilters(),
            )!,
          );
      await tester.pump();
      final requestsBefore = repo.requests.length;

      harness.go(['e2e4']);
      await tester.pump();

      // First frame: the answer, as final.
      expect(find.text('e2e4W0'), findsOneWidget);
      expect(find.text('startW0'), findsNothing);
      expect(_progressLine, findsNothing);

      await tester.pump(kDesktopPositionGamesNetworkDwell * 2);
      expect(repo.requests.length, requestsBefore);
    });

    testWidgets('stepping back answers from memory at once', (tester) async {
      final repo = _Repo(autoAnswer: true);
      final harness = _TableHarness(repo);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();

      harness.go(['e2e4']);
      await tester.pump(kDesktopPositionGamesNetworkDwell);
      await tester.pumpAndSettle();
      expect(find.text('e2e4W0'), findsOneWidget);
      final requestsBefore = repo.requests.length;

      harness.go(const []);
      await tester.pump();
      expect(find.text('startW0'), findsOneWidget);
      expect(_progressLine, findsNothing);
      await tester.pump(kDesktopPositionGamesNetworkDwell * 2);
      expect(repo.requests.length, requestsBefore);
    });

    testWidgets('attaches at once to a warm-up already on the wire', (
      tester,
    ) async {
      final repo = _Repo(autoAnswer: true);
      final harness = _TableHarness(repo);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();

      repo.autoAnswer = false;
      final container = harness.container(tester);
      container
          .read(explorerGamesPrefetchProvider)
          .warmNow(
            desktopExplorerChildGamesQuery(
              fen: _startFen,
              moves: const [],
              uci: 'e2e4',
              filters: const GamebaseFilters(),
            )!,
          );
      await tester.pump();
      expect(repo.requests.last.label, 'e2e4');

      harness.go(['e2e4']);
      await tester.pump();
      // Still the start position's rows, marked as not this answer.
      expect(find.text('startW0'), findsOneWidget);
      expect(_progressLine, findsOneWidget);

      repo.requests.last.answer();
      await tester.pump(Duration.zero);
      await tester.pump();
      // Well inside the dwell: the table used the request on the wire.
      expect(find.text('e2e4W0'), findsOneWidget);
      expect(_progressLine, findsNothing);
      await tester.pump(kDesktopPositionGamesNetworkDwell * 2);
      expect(repo.requests.where((r) => r.label == 'e2e4'), hasLength(1));
    });

    testWidgets('a saved copy paints at once, marked, and the answer '
        'replaces it', (tester) async {
      final repo = _Repo();
      final disk = _SavedDisk();
      final keys = ExplorerGamesCache(
        repository: () => repo,
        currentUserId: () => '',
      );
      disk.pages[keys.keyFor(
        GamebasePositionGamesQuery.desktopTablePage(
          fen: _startFen,
          filters: const GamebaseFilters(),
        ),
      )] = ExplorerGamesSnapshot(
        response: _page('saved'),
        fetchedAt: DateTime.now().subtract(const Duration(days: 2)),
        source: ExplorerGamesSource.disk,
      );
      final harness = _TableHarness(repo, disk: disk);
      await tester.pumpWidget(harness.build());
      await tester.pump();
      await tester.pump();

      // The saved rows, under the progress line, while the server is asked.
      expect(find.text('savedW0'), findsOneWidget);
      expect(_progressLine, findsOneWidget);
      expect(repo.requests, hasLength(1));

      repo.requests.single.answer('fresh');
      await tester.pumpAndSettle();
      expect(find.text('freshW0'), findsOneWidget);
      expect(find.text('savedW0'), findsNothing);
      expect(_progressLine, findsNothing);
    });

    testWidgets('a failed check keeps the saved copy, says so, and Retry asks '
        'again', (tester) async {
      final repo = _Repo();
      final disk = _SavedDisk();
      final keys = ExplorerGamesCache(
        repository: () => repo,
        currentUserId: () => '',
      );
      disk.pages[keys.keyFor(
        GamebasePositionGamesQuery.desktopTablePage(
          fen: _startFen,
          filters: const GamebaseFilters(),
        ),
      )] = ExplorerGamesSnapshot(
        response: _page('saved'),
        fetchedAt: DateTime.now().subtract(const Duration(days: 3)),
        source: ExplorerGamesSource.disk,
      );
      final harness = _TableHarness(repo, disk: disk);
      await tester.pumpWidget(harness.build());
      await tester.pump();
      await tester.pump();
      expect(find.text('savedW0'), findsOneWidget);

      repo.requests.single.fail();
      await tester.pumpAndSettle();
      expect(find.text('savedW0'), findsOneWidget);
      expect(find.textContaining('Couldn’t refresh'), findsOneWidget);
      expect(find.textContaining('3 days ago'), findsOneWidget);

      repo.autoAnswer = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(repo.requests, hasLength(2));
      expect(find.text('startW0'), findsOneWidget);
      expect(find.textContaining('Couldn’t refresh'), findsNothing);
    });

    testWidgets('a row opened while the next position loads opens at its own '
        'position', (tester) async {
      final repo = _Repo(autoAnswer: true);
      final harness = _TableHarness(repo);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();

      repo.autoAnswer = false;
      harness.go(['e2e4']);
      await tester.pump();
      expect(find.text('startW0'), findsOneWidget);
      expect(_progressLine, findsOneWidget);

      await _doubleClick(tester, find.text('startW0'));
      final args =
          harness
              .container(tester)
              .read(boardTabGameArgsByTabIdProvider)
              .values
              .single;
      expect(args.gameId, 'start-0');
      // Seeded at the start position it was listed for, not at 1.e4.
      expect(args.initialFen, _startFen);
      expect(args.databaseGamesPagination!.query.fen, _startFen);
      expect(args.databaseGamesPagination!.query.moves, isEmpty);
      expect(args.databaseTitle, 'Start position games');

      await tester.pump(kDesktopPositionGamesNetworkDwell);
      repo.requests.last.answer();
      await tester.pumpAndSettle();
    });

    testWidgets("the previous position's rows never stand in for a failed "
        'answer', (tester) async {
      final repo = _Repo(autoAnswer: true);
      final harness = _TableHarness(repo);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();
      expect(find.text('startW0'), findsOneWidget);

      repo.failNext = true;
      harness.go(['e2e4']);
      await tester.pump(kDesktopPositionGamesNetworkDwell);
      await tester.pumpAndSettle();

      expect(find.text('startW0'), findsNothing);
      expect(find.text("Couldn't load games"), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('e2e4W0'), findsOneWidget);
    });
  });

  group('saved copies', () {
    testWidgets('Retry asks again after a held warm page fails its refresh', (
      tester,
    ) async {
      final repo = _Repo(autoAnswer: true);
      var clock = DateTime(2026, 9, 26, 12);
      final harness = _TableHarness(repo, now: () => clock);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();

      harness
          .container(tester)
          .read(explorerGamesPrefetchProvider)
          .warmNow(
            desktopExplorerChildGamesQuery(
              fen: _startFen,
              moves: const [],
              uci: 'e2e4',
              filters: const GamebaseFilters(),
            )!,
          );
      await tester.pump();
      expect(repo.requests.where((r) => r.label == 'e2e4'), hasLength(1));

      clock = clock.add(const Duration(minutes: 5));
      repo.autoAnswer = false;
      harness.go(['e2e4']);
      await tester.pump();
      await tester.pump(kDesktopPositionGamesNetworkDwell);
      final refresh = repo.requests.where((r) => r.label == 'e2e4').toList();
      expect(refresh, hasLength(2));
      refresh.last.fail();
      await tester.pumpAndSettle();
      expect(find.text('e2e4W0'), findsOneWidget);
      expect(find.textContaining('Couldn’t refresh'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      final retried = repo.requests.where((r) => r.label == 'e2e4').toList();
      expect(retried, hasLength(3));
      expect(find.text('e2e4W0'), findsOneWidget);
      expect(_progressLine, findsOneWidget);
      retried.last.answer('retried');
      await tester.pumpAndSettle();
      expect(find.text('retriedW0'), findsOneWidget);
      expect(find.textContaining('Couldn’t refresh'), findsNothing);
      expect(_progressLine, findsNothing);
    });

    testWidgets('a warmed page held past the fresh window is checked, never '
        'shown as the answer', (tester) async {
      final repo = _Repo(autoAnswer: true);
      var clock = DateTime(2026, 9, 26, 12);
      final harness = _TableHarness(repo, now: () => clock);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();

      harness
          .container(tester)
          .read(explorerGamesPrefetchProvider)
          .warmNow(
            desktopExplorerChildGamesQuery(
              fen: _startFen,
              moves: const [],
              uci: 'e2e4',
              filters: const GamebaseFilters(),
            )!,
          );
      await tester.pump();
      expect(repo.requests.where((r) => r.label == 'e2e4'), hasLength(1));

      // The warm-up still holds that page five minutes later.
      clock = clock.add(const Duration(minutes: 5));
      repo.autoAnswer = false;
      harness.go(['e2e4']);
      await tester.pump();
      expect(find.text('e2e4W0'), findsOneWidget);
      expect(_progressLine, findsOneWidget);

      await tester.pump(kDesktopPositionGamesNetworkDwell);
      final asked = repo.requests.where((r) => r.label == 'e2e4').toList();
      expect(asked, hasLength(2));
      // Still the copy, still marked, until the server answers.
      expect(_progressLine, findsOneWidget);

      asked.last.answer('fresh');
      await tester.pumpAndSettle();
      expect(find.text('freshW0'), findsOneWidget);
      expect(find.text('e2e4W0'), findsNothing);
      expect(_progressLine, findsNothing);
    });

    testWidgets('a saved copy the disk finds after the server failed shows as '
        'not refreshed, with Retry', (tester) async {
      final repo = _Repo()..failNext = true;
      final disk =
          _SlowDisk()
            ..pages[_savedKey(_Repo(), _startFen)] = ExplorerGamesSnapshot(
              response: _page('saved'),
              fetchedAt: DateTime.now().subtract(const Duration(days: 2)),
              source: ExplorerGamesSource.disk,
            );
      final harness = _TableHarness(repo, disk: disk);
      await tester.pumpWidget(harness.build());
      await tester.pump();
      await tester.pump();
      // The server failed before the disk answered.
      expect(find.text("Couldn't load games"), findsOneWidget);

      disk.release();
      await tester.pump();
      await tester.pump();
      expect(find.text('savedW0'), findsOneWidget);
      expect(find.textContaining('Couldn’t refresh'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      // Nothing claims to be checking it: nothing is.
      expect(_progressLine, findsNothing);
      expect(repo.requests, hasLength(1));

      repo.autoAnswer = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(repo.requests, hasLength(2));
      expect(find.text('startW0'), findsOneWidget);
      expect(find.textContaining('Couldn’t refresh'), findsNothing);
    });

    testWidgets('a saved copy the disk finds after an empty answer stays '
        'unseen', (tester) async {
      final repo = _Repo();
      final disk =
          _SlowDisk()
            ..pages[_savedKey(_Repo(), _startFen)] = ExplorerGamesSnapshot(
              response: _page('saved'),
              fetchedAt: DateTime.now().subtract(const Duration(days: 2)),
              source: ExplorerGamesSource.disk,
            );
      final harness = _TableHarness(repo, disk: disk);
      await tester.pumpWidget(harness.build());
      await tester.pump();
      repo.requests.single.answer('start', 0);
      await tester.pump();
      await tester.pump();
      expect(find.text('No Games Found'), findsOneWidget);

      disk.release();
      await tester.pump();
      await tester.pump();
      expect(find.text('savedW0'), findsNothing);
      expect(find.text('No Games Found'), findsOneWidget);
      expect(_progressLine, findsNothing);
    });

    testWidgets('a game opened from a saved copy tells its rail to check page '
        '0 before paging', (tester) async {
      final repo = _Repo();
      final disk =
          _SavedDisk()
            ..pages[_savedKey(_Repo(), _startFen)] = ExplorerGamesSnapshot(
              response: _page('saved'),
              fetchedAt: DateTime.now().subtract(const Duration(days: 2)),
              source: ExplorerGamesSource.disk,
            );
      final harness = _TableHarness(repo, disk: disk);
      await tester.pumpWidget(harness.build());
      await tester.pump();
      await tester.pump();
      expect(find.text('savedW0'), findsOneWidget);
      expect(_progressLine, findsOneWidget);

      await _doubleClick(tester, find.text('savedW0'));
      final pagination =
          harness
              .container(tester)
              .read(boardTabGameArgsByTabIdProvider)
              .values
              .single
              .databaseGamesPagination!;
      expect(pagination.firstPageIsSavedCopy, isTrue);

      repo.requests.single.answer();
      await tester.pumpAndSettle();
    });
  });

  group('later pages', () {
    testWidgets('a page asked for before the page 0 on screen is asked again', (
      tester,
    ) async {
      final repo = _Repo(autoAnswer: true);
      var clock = DateTime(2026, 9, 26, 12);
      late WidgetRef widgetRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gamebaseRepositoryProvider.overrideWithValue(repo),
            explorerGamesCacheProvider.overrideWith((ref) {
              final cache = ExplorerGamesCache(
                repository: () => repo,
                currentUserId: () => '',
                now: () => clock,
              );
              ref.onDispose(cache.dispose);
              return cache;
            }),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      final page0 = GamebasePositionGamesQuery.desktopTablePage(
        fen: _startFen,
        filters: const GamebaseFilters(),
      );
      final page1 = page0.withPage(1);

      // Page 1 held from an earlier visit.
      await fetchDesktopPositionGamesPage(
        widgetRef,
        page1,
        exactFenSearch: false,
      );
      expect(repo.requests, hasLength(1));

      // A minute later a new page 0 lands.
      clock = clock.add(const Duration(minutes: 1));
      await fetchDesktopPositionGamesPage(
        widgetRef,
        page0,
        exactFenSearch: false,
      );
      final page0AskedAt = widgetRef
          .read(explorerGamesCacheProvider)
          .fetchedAtOf(widgetRef.read(positionGamesProvider(page0)).value!);
      expect(page0AskedAt, clock);

      // Paging on top of it asks for page 1 again rather than appending the
      // copy whose offsets may have moved.
      await fetchDesktopPositionGamesPage(
        widgetRef,
        page1,
        exactFenSearch: false,
        notOlderThan: page0AskedAt,
      );
      expect(repo.requests.map((r) => r.pageNumber), [1, 0, 1]);

      // Asked after page 0: kept.
      await fetchDesktopPositionGamesPage(
        widgetRef,
        page1,
        exactFenSearch: false,
        notOlderThan: page0AskedAt,
      );
      expect(repo.requests, hasLength(3));
    });
  });

  group('moves table warm-ups', () {
    const firstMoves = [
      'e2e4', 'd2d4', 'g1f3', 'c2c4', 'g2g3', 'b2b3', 'f2f4', 'b1c3', //
    ];

    testWidgets('warm the next positions once the reader stops, and any row '
        'the pointer rests on', (tester) async {
      final repo = _Repo(autoAnswer: true)
        ..aggregates = [
          for (final (i, uci) in firstMoves.indexed)
            MoveAggregate(
              uci: uci,
              white: 10,
              black: 10,
              draws: 10,
              total: 900 - i * 100,
            ),
        ];
      final pinned = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...desktopPremiumTestOverrides,
            gamebaseRepositoryProvider.overrideWithValue(repo),
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
            explorerGamesWarmUpsEnabledProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: SizedBox(
                width: 720,
                height: 900,
                child: DesktopOpeningExplorer(
                  onMove: (_) {},
                  onShowGames: pinned.add,
                  warmPositionGames: true,
                  warmPinnedGames: true,
                ),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DesktopOpeningExplorer)),
      );
      container.read(gamebaseExplorerProvider.notifier).setPosition(_startFen);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('Nf3'), findsOneWidget);
      // Not yet: the reader has not stopped long enough.
      expect(repo.requests, isEmpty);

      await tester.pump(kExplorerGamesRowWarmDwell);
      await tester.pump();
      await tester.pump();
      // The games each of the top rows leads to, in the order shown.
      expect(
        repo.requests.map((r) => r.label).toList(),
        firstMoves.take(kExplorerGamesPrefetchRows).toList(),
      );
      for (final request in repo.requests) {
        expect(request.fen, _play([request.label]).fen);
        expect(request.uci, isNull);
      }

      // A row below the warmed ones: resting the pointer on it warms it.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('f4')));
      await tester.pump(kExplorerGamesHoverWarmDelay ~/ 2);
      expect(repo.requests.where((r) => r.label == 'f2f4'), isEmpty);
      await tester.pump(kExplorerGamesHoverWarmDelay);
      expect(repo.requests.where((r) => r.label == 'f2f4'), hasLength(1));

      // Resting on a row's list icon warms the games it pins.
      await mouse.moveTo(
        tester.getCenter(find.byIcon(Icons.list_alt_rounded).at(7)),
      );
      await tester.pump(kExplorerGamesHoverWarmDelay);
      final pinnedRequest = repo.requests.last;
      expect(pinnedRequest.uci, 'b1c3');
      expect(pinnedRequest.fen, _startFen);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    });

    testWidgets('warm nothing when the host does not list global games', (
      tester,
    ) async {
      final repo = _Repo(autoAnswer: true)
        ..aggregates = const [
          MoveAggregate(uci: 'e2e4', white: 1, black: 1, draws: 1, total: 3),
        ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...desktopPremiumTestOverrides,
            gamebaseRepositoryProvider.overrideWithValue(repo),
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
            explorerGamesWarmUpsEnabledProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 720,
                height: 400,
                child: DesktopOpeningExplorer(onMove: (_) {}),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DesktopOpeningExplorer)),
      );
      container.read(gamebaseExplorerProvider.notifier).setPosition(_startFen);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(kExplorerGamesRowWarmDwell * 2);
      await tester.pumpAndSettle();
      expect(find.text('e4'), findsOneWidget);
      expect(repo.requests, isEmpty);
    });
  });

  group('pointer warm-ups', () {
    const firstMoves = [
      'e2e4', 'd2d4', 'g1f3', 'c2c4', 'g2g3', 'b2b3', //
      'f2f4', 'b1c3', 'e2e3', 'd2d3', 'c2c3', 'a2a3',
    ];

    testWidgets('moving down the list icons never fans out a request per '
        'row', (tester) async {
      final repo = _Repo(autoAnswer: true)
        ..aggregates = [
          for (final (i, uci) in firstMoves.indexed)
            MoveAggregate(
              uci: uci,
              white: 10,
              black: 10,
              draws: 10,
              total: 1200 - i * 100,
            ),
        ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...desktopPremiumTestOverrides,
            gamebaseRepositoryProvider.overrideWithValue(repo),
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
            explorerGamesWarmUpsEnabledProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: SizedBox(
                width: 720,
                height: 900,
                child: DesktopOpeningExplorer(
                  onMove: (_) {},
                  onShowGames: (_) {},
                  warmPositionGames: true,
                  warmPinnedGames: true,
                ),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DesktopOpeningExplorer)),
      );
      container.read(gamebaseExplorerProvider.notifier).setPosition(_startFen);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(kExplorerGamesRowWarmDwell);
      await tester.pumpAndSettle();
      // The top rows, warmed once the reader stopped.
      expect(repo.requests, hasLength(kExplorerGamesPrefetchRows));

      repo.autoAnswer = false;
      final icons = find.byIcon(Icons.list_alt_rounded);
      expect(icons, findsNWidgets(firstMoves.length));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      // A sweep down the column: no row is rested on, nothing is asked.
      for (var i = 0; i < firstMoves.length; i++) {
        await mouse.moveTo(tester.getCenter(icons.at(i)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await mouse.moveTo(Offset.zero);
      await tester.pump(kExplorerGamesHoverWarmDelay * 2);
      expect(repo.requests, hasLength(kExplorerGamesPrefetchRows));

      // Resting on every row in turn: never more than the hover slots out.
      for (var i = 0; i < firstMoves.length; i++) {
        await mouse.moveTo(tester.getCenter(icons.at(i)));
        await tester.pump(const Duration(milliseconds: 130));
        expect(
          repo.pending.length,
          lessThanOrEqualTo(kExplorerGamesHoverWarmConcurrency),
        );
      }
      expect(repo.pending, hasLength(kExplorerGamesHoverWarmConcurrency));

      // Leaving the table drops the row still waiting.
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      for (final request in repo.pending) {
        request.answer();
      }
      await tester.pumpAndSettle();
      expect(
        repo.requests,
        hasLength(
          kExplorerGamesPrefetchRows + kExplorerGamesHoverWarmConcurrency,
        ),
      );
      // Let the list icon's tooltip finish closing.
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

  group('auto-replay', () {
    testWidgets('a replay sends no games requests until it stops', (
      tester,
    ) async {
      final repo = _Repo(autoAnswer: true)..legalAggregates = true;
      var line = const <String>[];
      var replaying = true;
      late StateSetter setHarness;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...desktopPremiumTestOverrides,
            gamebaseRepositoryProvider.overrideWithValue(repo),
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
            explorerGamesWarmUpsEnabledProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: StatefulBuilder(
                builder: (context, setState) {
                  setHarness = setState;
                  // Wired as the board's Explorer tab wires them.
                  return SizedBox(
                    width: 720,
                    height: 1000,
                    child: Column(
                      children: [
                        SizedBox(
                          height: 420,
                          child: DesktopOpeningExplorer(
                            onMove: (_) {},
                            warmPositionGames: !replaying,
                          ),
                        ),
                        Expanded(
                          child: DesktopPositionGamesTable(
                            fen: _play(line).fen,
                            moves: line,
                            positionAutoplaying: replaying,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DesktopOpeningExplorer)),
      );
      final explorer = container.read(gamebaseExplorerProvider.notifier);
      explorer.setPositionWithMoves(_startFen, const []);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      final before = repo.requests.length;

      const replay = [
        'e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', //
        'f8c5', 'c2c3', 'g8f6', 'd2d4', 'e5d4',
      ];
      for (var i = 0; i < replay.length; i++) {
        final next = List<String>.unmodifiable(replay.take(i + 1));
        setHarness(() => line = next);
        explorer.setPositionWithMoves(_play(next).fen, next);
        await tester.pump(const Duration(milliseconds: 700));
      }
      expect(repo.requests.length, before);

      // The replay stops on its last position: it is read like any other.
      setHarness(() => replaying = false);
      await tester.pump();
      await tester.pump(kDesktopPositionGamesNetworkDwell);
      await tester.pump();
      final after = repo.requests.sublist(before);
      expect(after.where((r) => r.moves.length == replay.length), hasLength(1));
      expect(
        after.where((r) => r.moves.length == replay.length + 1),
        isNotEmpty,
      );
      await tester.pumpAndSettle();
    });
  });

  group('moves table aggregates', () {
    testWidgets('a revisited position answers in the same update, no request', (
      tester,
    ) async {
      final repo =
          _Repo()
            ..aggregates = const [
              MoveAggregate(
                uci: 'e7e5',
                white: 1,
                black: 1,
                draws: 1,
                total: 3,
              ),
            ];
      final container = ProviderContainer(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(gamebaseExplorerProvider, (_, _) {});
      addTearDown(sub.close);
      final notifier = container.read(gamebaseExplorerProvider.notifier);

      notifier.setPositionWithMoves(_e4Fen, const ['e2e4']);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        container.read(gamebaseExplorerProvider).moveAggregates,
        hasLength(1),
      );

      notifier.setPositionWithMoves(_startFen, const []);
      await tester.pump(const Duration(milliseconds: 250));
      final callsBefore = repo.aggregateCalls;

      notifier.setPositionWithMoves(_e4Fen, const ['e2e4']);
      final state = container.read(gamebaseExplorerProvider);
      expect(state.isLoading, isFalse);
      expect(state.moveAggregates.single.uci, 'e7e5');
      await tester.pump(const Duration(milliseconds: 250));
      expect(repo.aggregateCalls, callsBefore);
    });
  });
}
