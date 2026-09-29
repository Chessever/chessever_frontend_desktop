import 'dart:async';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/explorer_games_cache.dart';
import 'package:chessever/screens/gamebase/providers/explorer_games_prefetch.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:dartchess/dartchess.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Warming the explorer's games only pays off if the warmed request is the
/// *same* wire request the games table sends once the move is played. Any
/// drift in a single field (a filter the warm-up forgets, a page size that
/// differs by one) turns the whole prefetch into invisible dead work that
/// still costs the backend a request. These tests hold that identity, and
/// the bounds that keep warm-ups from crowding out the requests a reader
/// waits on.

const _moves = <String>[
  'e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', 'd2d3', 'f8c5', 'b1c3', //
];

Position _play(List<String> ucis) {
  Position position = Chess.initial;
  for (final uci in ucis) {
    position = position.play(Move.parse(uci)!);
  }
  return position;
}

final String _fen = _play(_moves).fen;

MoveAggregate _aggregate(String uci, int total) =>
    MoveAggregate(uci: uci, white: total, black: 0, draws: 0, total: total);

/// Every optional axis populated so a dropped field cannot hide.
const _filters = GamebaseFilters(
  timeControls: [TimeControl.classical, TimeControl.rapid],
  minRating: 2400,
  maxRating: 2900,
  playerIds: ['b1062433-ce11-45e5-84e5-a331d5f4ea34'],
  playerColor: GamebasePlayerColor.white,
  gameResult: GamebaseGameResult.whiteWins,
  isOnline: false,
  yearFrom: 2019,
  yearTo: 2026,
  sortBy: GamebaseSortField.avgElo,
  sortDirection: GamebaseSortDirection.asc,
);

/// Counts backend calls and answers with one row naming the request.
class _CountingRepository extends GamebaseRepository {
  _CountingRepository() : super(Dio(), baseUrl: 'https://example.test');

  int calls = 0;
  final List<Completer<void>> gates = <Completer<void>>[];
  bool failNext = false;

  /// When set, every request without a gate of its own waits in [held]
  /// until the test releases it: a server slow on everything.
  bool holdAll = false;
  final List<Completer<void>> held = <Completer<void>>[];

  void releaseAll() {
    holdAll = false;
    for (final gate in held) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  /// `fen|uci` of every request, in the order they were sent.
  final List<String> requested = <String>[];

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
    calls += 1;
    requested.add('$fen|$uci');
    if (gates.isNotEmpty) {
      await gates.removeAt(0).future;
    } else if (holdAll) {
      final gate = Completer<void>();
      held.add(gate);
      await gate.future;
    }
    if (failNext) {
      failNext = false;
      throw Exception('backend down');
    }
    return GamebaseSearchQueryResponse(
      status: 'success',
      data: [
        {'id': 'game-${moves.isEmpty ? '' : moves.last}-$uci'},
      ],
      metadata: GamebasePaginationMetadata(
        pageNumber: pageNumber,
        pageSize: pageSize,
      ),
    );
  }
}

ProviderContainer _container(GamebaseRepository repository) {
  final container = ProviderContainer(
    overrides: [
      gamebaseRepositoryProvider.overrideWithValue(repository),
      explorerGamesWarmUpsEnabledProvider.overrideWithValue(true),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('buildExplorerGamesPrefetchQueries', () {
    test('warms exactly the page the games table reads after the move', () {
      final queries = buildExplorerGamesPrefetchQueries(
        fen: _fen,
        moves: _moves,
        aggregates: [_aggregate('d7d6', 23)],
        filters: _filters,
      );
      // The table, once d7d6 is played on the board, lists the new
      // position's games along the extended line, with the same filters.
      final table = GamebasePositionGamesQuery.desktopTablePage(
        fen: _play([..._moves, 'd7d6']).fen,
        moves: [..._moves, 'd7d6'],
        filters: _filters,
      );
      expect(queries, [table]);
      expect(queries.single.pageSize, kDesktopPositionGamesPageSize);
      expect(queries.single.notationPlies, kDesktopPositionGamesNotationPlies);
      expect(queries.single.uci, isNull);
    });

    test('carries every filter axis into the request', () {
      final query =
          buildExplorerGamesPrefetchQueries(
            fen: _fen,
            moves: _moves,
            aggregates: [_aggregate('d7d6', 23)],
            filters: _filters,
          ).single;
      expect(query.timeControl, TimeControl.classical);
      expect(query.minRating, 2400);
      expect(query.maxRating, 2900);
      expect(query.playerId, 'b1062433-ce11-45e5-84e5-a331d5f4ea34');
      expect(query.color, 'white');
      expect(query.result, GamebaseGameResult.whiteWins.apiValue);
      expect(query.isOnline, isFalse);
      expect(query.yearFrom, 2019);
      expect(query.yearTo, 2026);
      expect(query.sortBy, GamebaseSortField.avgElo);
      expect(query.sortDirection, GamebaseSortDirection.asc);
    });

    test('castling rows warm the key the board line sends', () {
      const line = ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6'];
      final fen = _play(line).fen;
      final warmed =
          buildExplorerGamesPrefetchQueries(
            fen: fen,
            moves: line,
            // The server spells castling king-to-g.
            aggregates: [_aggregate('e1g1', 50)],
            filters: const GamebaseFilters(),
          ).single;
      // The board's line spells it king-to-rook (dartchess).
      final castled = _play([...line, 'e1h1']);
      final table = GamebasePositionGamesQuery.desktopTablePage(
        fen: castled.fen,
        moves: [...line, 'e1h1'],
        filters: const GamebaseFilters(),
      );
      final cache = ExplorerGamesCache(
        repository: _CountingRepository.new,
        currentUserId: () => '',
      );
      expect(warmed.fen, castled.fen);
      expect(cache.keyFor(warmed), cache.keyFor(table));
    });

    test('warms the visible rows in order, top rows only', () {
      final aggregates = [
        for (final (i, uci)
            in [
              'h7h6', 'd7d6', 'a7a6', 'e8g8', 'c6a5', 'h7h5', 'a7a5', 'g8h8', //
            ].indexed)
          _aggregate(uci, 100 - i),
      ];
      final queries = buildExplorerGamesPrefetchQueries(
        fen: _fen,
        moves: _moves,
        aggregates: aggregates,
        filters: const GamebaseFilters(),
      );
      expect(queries, hasLength(kExplorerGamesPrefetchRows));
      expect(
        queries.map((query) => query.moves.last),
        aggregates.take(kExplorerGamesPrefetchRows).map((a) => a.uci),
      );
    });

    test('skips moves that are not legal here, and an empty table', () {
      expect(
        buildExplorerGamesPrefetchQueries(
          fen: _fen,
          moves: _moves,
          aggregates: [_aggregate('e2e4', 3)],
          filters: const GamebaseFilters(),
        ),
        isEmpty,
      );
      expect(
        buildExplorerGamesPrefetchQueries(
          fen: _fen,
          moves: _moves,
          aggregates: const [],
          filters: const GamebaseFilters(),
        ),
        isEmpty,
      );
    });

    test('the list icon warms the pinned page at the current position', () {
      final pinned = desktopExplorerPinnedGamesQuery(
        fen: _fen,
        moves: _moves,
        uci: ' d7d6 ',
        filters: _filters,
      );
      expect(
        pinned,
        GamebasePositionGamesQuery.desktopTablePage(
          fen: _fen,
          moves: _moves,
          uci: 'd7d6',
          filters: _filters,
        ),
      );
    });
  });

  group('explorerGamesPrefetchSignature', () {
    test(
      'changes when a transposition reaches the same FEN by another line',
      () {
        final aggregates = [_aggregate('d7d6', 23), _aggregate('a7a6', 16)];
        final transposed = [..._moves]..swap(0, 2);
        expect(
          explorerGamesPrefetchSignature(
            fen: _fen,
            moves: _moves,
            filters: const GamebaseFilters(),
            aggregates: aggregates,
          ),
          isNot(
            explorerGamesPrefetchSignature(
              fen: _fen,
              moves: transposed,
              filters: const GamebaseFilters(),
              aggregates: aggregates,
            ),
          ),
        );
      },
    );

    test('changes with the rows and the filters', () {
      int signature({
        List<MoveAggregate>? aggregates,
        GamebaseFilters filters = const GamebaseFilters(),
      }) => explorerGamesPrefetchSignature(
        fen: _fen,
        moves: _moves,
        filters: filters,
        aggregates: aggregates ?? [_aggregate('d7d6', 1)],
      );
      expect(signature(), signature());
      expect(
        signature(),
        isNot(signature(aggregates: [_aggregate('a7a6', 1)])),
      );
      expect(
        signature(),
        isNot(signature(filters: const GamebaseFilters(minRating: 2000))),
      );
    });
  });

  group('ExplorerGamesPrefetcher', () {
    test('a warmed row answers the table without a second request', () async {
      final repository = _CountingRepository();
      final container = _container(repository);

      final queries = buildExplorerGamesPrefetchQueries(
        fen: _fen,
        moves: _moves,
        aggregates: [_aggregate('d7d6', 23)],
        filters: _filters,
      );
      container.read(explorerGamesPrefetchProvider).warm(queries);
      await _settle();
      expect(repository.calls, 1);

      // What the table does once the move is played. `positionGamesProvider`
      // is autoDispose, so this only stays at one call if the warm-up still
      // holds the entry.
      final response = await container.read(
        positionGamesProvider(queries.single).future,
      );
      expect(response.data.single['id'], 'game-d7d6-null');
      expect(repository.calls, 1);
      // And the memory snapshot a table peeks by wire key is current.
      final cache = container.read(explorerGamesCacheProvider);
      expect(cache.isSnapshotFresh(cache.peek(queries.single)!), isTrue);
    });

    test('off: warming sends nothing', () async {
      final repository = _CountingRepository();
      final container = ProviderContainer(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      // Off by default under `flutter test`.
      expect(container.read(explorerGamesWarmUpsEnabledProvider), isFalse);

      final prefetcher = container.read(explorerGamesPrefetchProvider);
      final queries = buildExplorerGamesPrefetchQueries(
        fen: _fen,
        moves: _moves,
        aggregates: [_aggregate('d7d6', 23)],
        filters: _filters,
      );
      prefetcher.warm(queries);
      prefetcher.warmNow(queries.single);
      await _settle();
      expect(repository.calls, 0);
    });

    test('a failed warm is dropped so the click can retry', () async {
      final repository = _CountingRepository()..failNext = true;
      final container = _container(repository);

      final query =
          buildExplorerGamesPrefetchQueries(
            fen: _fen,
            moves: _moves,
            aggregates: [_aggregate('d7d6', 23)],
            filters: _filters,
          ).single;
      final prefetcher = container.read(explorerGamesPrefetchProvider);
      prefetcher.warm([query]);
      await _settle();
      expect(prefetcher.isWarm(query), isFalse);

      prefetcher.warmNow(query);
      await _settle();
      expect(repository.calls, 2);
      expect(prefetcher.isWarm(query), isTrue);
    });

    test('a request already on the wire is not sent twice', () async {
      final repository = _CountingRepository();
      final gate = Completer<void>();
      repository.gates.add(gate);
      final container = _container(repository);
      final query =
          buildExplorerGamesPrefetchQueries(
            fen: _fen,
            moves: _moves,
            aggregates: [_aggregate('d7d6', 23)],
            filters: _filters,
          ).single;

      // The table asked first; the warm-up must not add a second request.
      final tableRead = container.read(positionGamesProvider(query).future);
      container.read(explorerGamesPrefetchProvider).warmNow(query);
      await _settle();
      expect(repository.calls, 1);
      gate.complete();
      await tableRead;
    });
  });

  group('warm-up queue', () {
    // Ten distinct real positions: the start position after ten first moves.
    const firstMoves = [
      'e2e4', 'd2d4', 'c2c4', 'g1f3', 'b1c3', //
      'f2f4', 'g2g3', 'b2b3', 'e2e3', 'd2d3',
    ];
    const replies = ['e7e5', 'd7d5', 'c7c5', 'g8f6', 'b8c6', 'e7e6'];

    List<GamebasePositionGamesQuery> positionQueries(int index) =>
        buildExplorerGamesPrefetchQueries(
          fen: _play([firstMoves[index]]).fen,
          moves: [firstMoves[index]],
          aggregates: [
            for (final reply in replies)
              if (_play([firstMoves[index]]).isLegal(Move.parse(reply)!))
                _aggregate(reply, 10),
          ],
          filters: const GamebaseFilters(),
        );

    Set<String> parentsOf(Iterable<GamebasePositionGamesQuery> queries) => {
      for (final query in queries) query.moves.first,
    };

    test(
      'stepping through positions keeps only the newest one queued',
      () async {
        final repository = _CountingRepository()..holdAll = true;
        final container = _container(repository);
        addTearDown(repository.releaseAll);
        final prefetcher = container.read(explorerGamesPrefetchProvider);

        for (var i = 0; i < 10; i++) {
          prefetcher.warm(positionQueries(i));
          await Future<void>.delayed(Duration.zero);
          expect(
            prefetcher.queued.length,
            lessThanOrEqualTo(kExplorerGamesPrefetchQueueLimit),
          );
          // Nothing queued for a position the reader has already left.
          expect(parentsOf(prefetcher.queued), {firstMoves[i]});
        }
        // The first two positions filled the overall ceiling between them.
        expect(repository.calls, kExplorerGamesPrefetchInFlightCeiling);

        // A request lands: the position being read goes next.
        repository.held.first.complete();
        await _settle();
        expect(
          repository.requested[kExplorerGamesPrefetchInFlightCeiling],
          startsWith('${positionQueries(9).first.fen}|'),
        );
      },
    );

    test(
      "a slow position the reader left does not hold the next one's slots",
      () async {
        final repository = _CountingRepository()..holdAll = true;
        final container = _container(repository);
        addTearDown(repository.releaseAll);
        final prefetcher = container.read(explorerGamesPrefetchProvider);

        prefetcher.warm(positionQueries(0));
        await Future<void>.delayed(Duration.zero);
        expect(repository.calls, kExplorerGamesPrefetchConcurrency);

        prefetcher.warm(positionQueries(1));
        await Future<void>.delayed(Duration.zero);
        final childFensOfB = positionQueries(1).map((q) => q.fen).toSet();
        final forB = [
          for (final request in repository.requested)
            if (childFensOfB.contains(request.split('|').first)) request,
        ];
        expect(forB, hasLength(kExplorerGamesPrefetchConcurrency));
        expect(
          repository.calls,
          lessThanOrEqualTo(kExplorerGamesPrefetchInFlightCeiling),
        );
      },
    );

    test(
      'rows that leave the screen take their waiting warm-ups with them',
      () async {
        final repository = _CountingRepository()..holdAll = true;
        final container = _container(repository);
        addTearDown(repository.releaseAll);
        final prefetcher = container.read(explorerGamesPrefetchProvider);

        final a = positionQueries(0);
        prefetcher.warm(a);
        await Future<void>.delayed(Duration.zero);
        expect(repository.calls, kExplorerGamesPrefetchConcurrency);
        expect(prefetcher.queued, hasLength(a.length - repository.calls));

        prefetcher.cancel(a);
        expect(prefetcher.queued, isEmpty);

        repository.releaseAll();
        await _settle();
        expect(repository.calls, kExplorerGamesPrefetchConcurrency);
        // The answers that did land still serve a click.
        expect(prefetcher.isWarm(a.first), isTrue);
      },
    );

    test('warming the same queries twice queues them once', () async {
      final repository = _CountingRepository()..holdAll = true;
      final container = _container(repository);
      addTearDown(repository.releaseAll);
      final prefetcher = container.read(explorerGamesPrefetchProvider);

      final a = positionQueries(0);
      prefetcher.warm(a);
      prefetcher.warm(a);
      await Future<void>.delayed(Duration.zero);
      expect(prefetcher.queued.toSet().length, prefetcher.queued.length);
      expect(prefetcher.queued.length, a.length - repository.calls);
    });

    test('changing the filters drops what the old filters still had '
        'waiting', () async {
      final repository = _CountingRepository()..holdAll = true;
      final container = _container(repository);
      addTearDown(repository.releaseAll);
      final prefetcher = container.read(explorerGamesPrefetchProvider);

      List<GamebasePositionGamesQuery> rows(GamebaseFilters filters) =>
          buildExplorerGamesPrefetchQueries(
            fen: _play([firstMoves[0]]).fen,
            moves: [firstMoves[0]],
            aggregates: [for (final reply in replies) _aggregate(reply, 10)],
            filters: filters,
          );

      final unrated = rows(const GamebaseFilters());
      prefetcher.warm(unrated);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, kExplorerGamesPrefetchConcurrency);

      // Same position, new filters: the old rows still waiting are gone,
      // and their requests on the wire hold none of the new rows' slots.
      final rated = rows(const GamebaseFilters(minRating: 2600));
      prefetcher.warm(rated);
      await Future<void>.delayed(Duration.zero);
      expect(prefetcher.queued, everyElement(isIn(rated)));
      expect(repository.calls, kExplorerGamesPrefetchConcurrency * 2);

      repository.releaseAll();
      await _settle();
      await _settle();
      expect(
        repository.calls,
        kExplorerGamesPrefetchConcurrency + rated.length,
      );
    });

    test(
      'resting on row after row keeps hover warm-ups to their slots',
      () async {
        final repository = _CountingRepository()..holdAll = true;
        final container = _container(repository);
        addTearDown(repository.releaseAll);
        final prefetcher = container.read(explorerGamesPrefetchProvider);

        final rows = [...positionQueries(0), ...positionQueries(1)];
        for (final row in rows) {
          prefetcher.warmHover(row);
          await Future<void>.delayed(Duration.zero);
          expect(
            repository.calls,
            lessThanOrEqualTo(kExplorerGamesHoverWarmConcurrency),
          );
        }
        expect(repository.calls, kExplorerGamesHoverWarmConcurrency);
        // Only the row rested on last waits, for the next free slot.
        expect(prefetcher.hoverWaiting, rows.last);

        repository.held.first.complete();
        await _settle();
        expect(repository.calls, kExplorerGamesHoverWarmConcurrency + 1);
        expect(repository.requested.last, '${rows.last.fen}|null');
        expect(prefetcher.hoverWaiting, isNull);
      },
    );

    test('a row the pointer left is dropped from the hover wait', () async {
      final repository = _CountingRepository()..holdAll = true;
      final container = _container(repository);
      addTearDown(repository.releaseAll);
      final prefetcher = container.read(explorerGamesPrefetchProvider);

      final rows = positionQueries(0);
      for (final row in rows.take(kExplorerGamesHoverWarmConcurrency + 1)) {
        prefetcher.warmHover(row);
      }
      final left = rows[kExplorerGamesHoverWarmConcurrency];
      expect(prefetcher.hoverWaiting, left);
      prefetcher.cancelHover(left);
      expect(prefetcher.hoverWaiting, isNull);

      repository.releaseAll();
      await _settle();
      expect(repository.calls, kExplorerGamesHoverWarmConcurrency);
    });

    test('a pointer head start does not wait for a free slot', () async {
      final repository = _CountingRepository()..holdAll = true;
      final container = _container(repository);
      addTearDown(repository.releaseAll);
      final prefetcher = container.read(explorerGamesPrefetchProvider);

      final queries = positionQueries(0);
      prefetcher.warm(queries);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, kExplorerGamesPrefetchConcurrency);

      final pressed = queries.last;
      prefetcher.warmNow(pressed);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, kExplorerGamesPrefetchConcurrency + 1);
      expect(repository.requested.last, '${pressed.fen}|null');
      expect(prefetcher.queued, isNot(contains(pressed)));
    });
  });
}

extension on List<String> {
  void swap(int a, int b) {
    final t = this[a];
    this[a] = this[b];
    this[b] = t;
  }
}
