import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/explorer_games_cache.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The explorer's games cache (desktop port of the phone app's): what it keys
/// pages by, what it keeps, how long, and when it forgets. Every rule here is
/// one a stale or crossed page would break silently, so each has a test that
/// fails the moment it does.

const _fen =
    'r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP2PPP/R1BQK2R b KQkq - 3 5';
const _moves = <String>[
  'e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', 'd2d3', 'f8c5', 'b1c3', //
];

Map<String, dynamic> _row(String id) => <String, dynamic>{
  'id': id,
  'white': 'White $id',
  'black': 'Black $id',
  'result': '1-0',
  'whiteElo': 2700,
  'blackElo': 2650,
  'date': '2024-05-12',
};

GamebaseSearchQueryResponse _page(
  List<String> ids, {
  int pageNumber = 0,
  bool hasMore = true,
  int? totalCount,
}) => GamebaseSearchQueryResponse(
  status: 'success',
  data: [for (final id in ids) _row(id)],
  metadata: GamebasePaginationMetadata(
    pageNumber: pageNumber,
    pageSize: 25,
    totalCount: totalCount,
    hasMoreValue: hasMore,
  ),
);

/// Answers every request with one row naming it, and counts the requests.
class _Repo extends GamebaseRepository {
  _Repo({String? baseUrl})
    : super(Dio(), baseUrl: baseUrl ?? 'https://example.test');

  int calls = 0;
  Completer<void>? gate;

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
    calls++;
    await gate?.future;
    return _page(['$uci-$pageNumber-$calls'], pageNumber: pageNumber);
  }

  @override
  Future<GamebaseSearchQueryResponse> getFenPositionGames({
    required String fen,
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
    calls++;
    await gate?.future;
    return _page(['fen-$pageNumber-$calls'], pageNumber: pageNumber);
  }
}

class _FailingRepo extends GamebaseRepository {
  _FailingRepo() : super(Dio(), baseUrl: 'https://example.test');

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
  }) async => throw Exception('backend down');
}

/// Records the request Dio would send, and answers an empty page.
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'status': 'success',
        'data': <Object?>[],
        'metadata': {'pageNumber': 0, 'pageSize': 25, 'hasMore': false},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

GamebasePositionGamesQuery _query({
  String? uci,
  List<String> moves = _moves,
  int pageNumber = 0,
  GamebaseFilters filters = const GamebaseFilters(),
  String fen = _fen,
}) => GamebasePositionGamesQuery.desktopTablePage(
  fen: fen,
  filters: filters,
  moves: moves,
  uci: uci,
  pageNumber: pageNumber,
);

void main() {
  group('response JSON', () {
    test('round-trips every field of a page', () {
      final pages = [
        _page(['a', 'b'], totalCount: 2, hasMore: false),
        const GamebaseSearchQueryResponse(
          status: 'success',
          data: [
            {
              'id': 'x',
              'continuation': ['e2e4', 'e7e5'],
              'whiteFideId': 1503014,
              'nested': {
                'k': null,
                'list': [1, 2.5, true],
              },
            },
          ],
          metadata: GamebasePaginationMetadata(
            pageNumber: 3,
            pageSize: 10,
            totalCountIsEstimate: true,
          ),
        ),
      ];
      for (final page in pages) {
        final back = GamebaseSearchQueryResponse.fromJson(
          jsonDecode(jsonEncode(page.toJson())) as Map<String, dynamic>,
        );
        expect(back.status, page.status);
        expect(back.data, page.data);
        expect(back.metadata.pageNumber, page.metadata.pageNumber);
        expect(back.metadata.pageSize, page.metadata.pageSize);
        expect(back.metadata.totalCount, page.metadata.totalCount);
        expect(back.metadata.hasMoreValue, page.metadata.hasMoreValue);
        expect(back.metadata.hasMore, page.metadata.hasMore);
        expect(
          back.metadata.totalCountIsEstimate,
          page.metadata.totalCountIsEstimate,
        );
        expect(jsonEncode(back.toJson()), jsonEncode(page.toJson()));
      }
    });
  });

  group('wire request', () {
    test('describes exactly what getPositionGames sends', () async {
      for (final moves in [_moves, const <String>[]]) {
        final adapter = _CapturingAdapter();
        final repo = GamebaseRepository(
          Dio()..httpClientAdapter = adapter,
          baseUrl: 'https://example.test',
        );
        const args = (
          uci: 'd7d6',
          sortBy: GamebaseSortField.avgElo,
          sortDirection: GamebaseSortDirection.asc,
        );
        final described = repo.positionGamesRequest(
          fen: _fen,
          moves: moves,
          uci: args.uci,
          minRating: 2400,
          sortBy: args.sortBy,
          sortDirection: args.sortDirection,
          pageSize: 25,
          notationPlies: 16,
        );
        await repo.getPositionGames(
          fen: _fen,
          moves: moves,
          uci: args.uci,
          minRating: 2400,
          sortBy: args.sortBy,
          sortDirection: args.sortDirection,
          pageSize: 25,
          notationPlies: 16,
        );
        final sent = adapter.last!;
        expect(sent.method, described.method);
        expect(
          sent.uri.replace(query: '').toString().replaceAll('?', ''),
          described.url,
        );
        if (described.method == 'POST') {
          expect(sent.data, described.payload);
          expect(described.url, endsWith('/api/game-position/games/query'));
          // Same body, byte for byte, as the pre-cache builder produced.
          expect(
            jsonEncode(described.payload),
            jsonEncode(
              buildPositionGamesQueryBody(
                fen: _fen,
                moves: _moves,
                uci: args.uci,
                minRating: 2400,
                sortBy: args.sortBy,
                sortDirection: args.sortDirection,
                pageSize: 25,
                notationPlies: 16,
              ),
            ),
          );
        } else {
          expect(sent.queryParameters, described.payload);
          expect(described.url, endsWith('/api/game-position/games'));
        }
      }
    });

    test('describes exactly what getFenPositionGames sends', () async {
      final adapter = _CapturingAdapter();
      final repo = GamebaseRepository(
        Dio()..httpClientAdapter = adapter,
        baseUrl: 'https://example.test',
      );
      final described = repo.fenPositionGamesRequest(
        fen: _fen.split(' ').take(4).join(' '),
        uci: ' c1g5 ',
        playerId: ' p1 ',
        timeControl: TimeControl.blitz,
        pageNumber: 1,
        pageSize: 25,
        notationPlies: 16,
      );
      await repo.getFenPositionGames(
        fen: _fen.split(' ').take(4).join(' '),
        uci: ' c1g5 ',
        playerId: ' p1 ',
        timeControl: TimeControl.blitz,
        pageNumber: 1,
        pageSize: 25,
        notationPlies: 16,
      );
      expect(adapter.last!.method, 'GET');
      expect(adapter.last!.queryParameters, described.payload);
      expect(described.url, 'https://example.test/api/game-position/fen/games');
      expect(described.payload.keys.toList(), [
        'fen',
        'pageNumber',
        'pageSize',
        'uci',
        'playerId',
        'timeControl',
        'notationPlies',
      ]);
      expect(described.payload['fen'], endsWith(' 0 1'));
      expect(described.payload['uci'], 'c1g5');
      expect(described.payload['playerId'], 'p1');
    });

    test('identity ignores the order fields were built in', () {
      const a = GamebaseWireRequest(
        method: 'GET',
        url: 'u',
        payload: {
          'b': 1,
          'a': {'y': 2, 'x': 3},
        },
      );
      const b = GamebaseWireRequest(
        method: 'GET',
        url: 'u',
        payload: {
          'a': {'x': 3, 'y': 2},
          'b': 1,
        },
      );
      expect(a.identity, b.identity);
      expect(explorerGamesCacheKey(a), explorerGamesCacheKey(b));
    });
  });

  group('cache keys', () {
    final cache = ExplorerGamesCache(
      repository: _Repo.new,
      currentUserId: () => 'u',
    );

    test('one key per wire request', () {
      final keys = <String>{
        cache.keyFor(_query()),
        cache.keyFor(_query(uci: 'd7d6')),
        cache.keyFor(_query(uci: 'd7d6', pageNumber: 1)),
        cache.keyFor(_query(filters: const GamebaseFilters(minRating: 2400))),
        cache.keyFor(
          GamebasePositionGamesQuery.desktopTablePage(
            fen: _fen,
            filters: const GamebaseFilters(),
            moves: _moves,
            sortBy: GamebaseSortField.whiteElo,
          ),
        ),
      };
      expect(keys, hasLength(5));

      // A different base URL (another deployment) never shares a page.
      final elsewhere = ExplorerGamesCache(
        repository: () => _Repo(baseUrl: 'https://other.test'),
        currentUserId: () => 'u',
      );
      expect(elsewhere.keyFor(_query()), isNot(cache.keyFor(_query())));
    });

    test('shapes the wire normalizes share a key', () {
      // A 4-field FEN is sent with default counters.
      final start = Chess.initial.fen;
      expect(
        cache.keyFor(
          _query(fen: start.split(' ').take(4).join(' '), moves: const []),
        ),
        cache.keyFor(_query(fen: start, moves: const [])),
      );

      // Castling in dartchess's king-to-rook spelling is sent as king-to-g.
      const line = [
        'e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', //
      ];
      Position position = Chess.initial;
      for (final uci in line) {
        position = position.play(Move.parse(uci)!);
      }
      final castled = position.play(Move.parse('e1g1')!).fen;
      expect(
        cache.keyFor(_query(fen: castled, moves: [...line, 'e1h1'])),
        cache.keyFor(_query(fen: castled, moves: [...line, 'e1g1'])),
      );

      // Whitespace around a move filter is trimmed on the wire.
      expect(
        cache.keyFor(_query(uci: ' d7d6 ')),
        cache.keyFor(_query(uci: 'd7d6')),
      );
    });
  });

  group('in-flight requests', () {
    test('identical wire requests share one network call', () async {
      final repo = _Repo()..gate = Completer<void>();
      final cache = ExplorerGamesCache(
        repository: () => repo,
        currentUserId: () => 'u',
      );

      final first = cache.fetch(_query(uci: 'd7d6'));
      final second = cache.fetch(_query(uci: ' d7d6'));
      expect(cache.isFetching(_query(uci: 'd7d6')), isTrue);
      repo.gate!.complete();
      final results = await Future.wait([first, second]);

      expect(repo.calls, 1);
      expect(identical(results.first, results.last), isTrue);
      expect(cache.isFetching(_query(uci: 'd7d6')), isFalse);

      // Settled: the next fetch goes to the server again.
      await cache.fetch(_query(uci: 'd7d6'));
      expect(repo.calls, 2);
    });

    test('a failed request is not remembered', () async {
      final cache = ExplorerGamesCache(
        repository: _FailingRepo.new,
        currentUserId: () => 'u',
      );
      await expectLater(cache.fetch(_query()), throwsException);
      expect(cache.peek(_query()), isNull);
      expect(cache.isFetching(_query()), isFalse);
    });
  });

  group('freshness', () {
    test(
      'a fetched page is current for two minutes, then only a snapshot',
      () async {
        var now = DateTime(2026, 9, 26, 12);
        final cache = ExplorerGamesCache(
          repository: _Repo.new,
          currentUserId: () => 'u',
          now: () => now,
        );
        final response = await cache.fetch(_query());
        expect(cache.isFresh(response), isTrue);
        final held = cache.peek(_query())!;
        expect(held.response, same(response));
        expect(held.source, ExplorerGamesSource.memory);
        expect(cache.isSnapshotFresh(held), isTrue);

        now = now.add(kExplorerGamesFreshFor + const Duration(seconds: 1));
        expect(cache.isFresh(response), isFalse);
        // Still there to paint, never passed off as current.
        expect(cache.peek(_query())?.response, same(response));
        expect(cache.isSnapshotFresh(cache.peek(_query())!), isFalse);

        // A page that did not come through the cache has no known age.
        expect(cache.isFresh(_page(['x'])), isFalse);
      },
    );

    test('the send time is the page\'s age, not the arrival time', () async {
      var now = DateTime(2026, 9, 26, 12);
      final repo = _Repo()..gate = Completer<void>();
      final cache = ExplorerGamesCache(
        repository: () => repo,
        currentUserId: () => 'u',
        now: () => now,
      );
      final sentAt = now;
      final pending = cache.fetch(_query());
      now = now.add(const Duration(seconds: 30));
      repo.gate!.complete();
      final response = await pending;
      expect(cache.fetchedAtOf(response), sentAt);
    });

    test('later pages are never kept as snapshots', () async {
      final cache = ExplorerGamesCache(
        repository: _Repo.new,
        currentUserId: () => 'u',
      );
      await cache.fetch(_query(pageNumber: 1));
      expect(cache.peek(_query(pageNumber: 1)), isNull);
    });

    test('memory keeps the newest pages within its cap', () async {
      final cache = ExplorerGamesCache(
        repository: _Repo.new,
        currentUserId: () => 'u',
        memoryPages: 3,
      );
      for (final uci in ['a2a3', 'a2a4', 'b2b3', 'b2b4']) {
        await cache.fetch(_query(uci: uci));
      }
      expect(cache.peek(_query(uci: 'a2a3')), isNull);
      for (final uci in ['a2a4', 'b2b3', 'b2b4']) {
        expect(cache.peek(_query(uci: uci)), isNotNull);
      }
    });
  });

  group('retention', () {
    test(
      'a first page stays answerable for two minutes, then is released',
      () async {
        var now = DateTime(2026, 9, 26, 12);
        final repo = _Repo();
        final container = ProviderContainer(
          overrides: [
            gamebaseRepositoryProvider.overrideWithValue(repo),
            explorerGamesCacheProvider.overrideWith((ref) {
              final cache = ExplorerGamesCache(
                repository: () => repo,
                currentUserId: () => 'u',
                now: () => now,
              );
              ref.onDispose(cache.dispose);
              return cache;
            }),
          ],
        );
        addTearDown(container.dispose);

        final first = _query();
        await container.read(positionGamesProvider(first).future);
        // Stepping through 60 other positions within the window.
        for (var i = 0; i < 60; i++) {
          await container.read(
            positionGamesProvider(_query(uci: 'a2a3-$i')).future,
          );
          now = now.add(const Duration(milliseconds: 500));
        }
        await Future<void>.delayed(Duration.zero);

        // Stepping back: answered from memory, no loading frame, no request.
        final back = container.read(positionGamesProvider(first));
        expect(back.isLoading, isFalse);
        expect(back.hasValue, isTrue);
        expect(repo.calls, 61);

        // Past the retention window the page is released on the next call.
        now = now.add(kExplorerGamesRetainFor);
        container.read(explorerGamesCacheProvider).peek(_query());
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(explorerGamesCacheProvider).debugRetainedCount,
          0,
        );
        expect(container.read(positionGamesProvider(first)).isLoading, isTrue);
        await container.read(positionGamesProvider(first).future);
      },
    );

    test('only the app turns the release timer on', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(explorerGamesCacheProvider).releaseOnTimer,
        isFalse,
      );
    });
  });

  group('disk store', () {
    late Directory dir;
    var now = DateTime(2026, 9, 26, 12);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('explorer_games_test');
      now = DateTime(2026, 9, 26, 12);
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    FileExplorerGamesDiskStore store({
      int maxPages = 10,
      int? maxBytes,
      bool readOnly = false,
    }) => FileExplorerGamesDiskStore(
      directory: () async => dir,
      maxPages: maxPages,
      maxBytes: maxBytes ?? kExplorerGamesDiskBytes,
      readOnly: readOnly,
      now: () => now,
    );

    String key(String name) => explorerGamesCacheKey(
      GamebaseWireRequest(method: 'GET', url: name, payload: const {}),
    );

    Future<List<String>> filesOnDisk() async => [
      await for (final entity in dir.list())
        if (entity is File && entity.path.endsWith('.json'))
          entity.uri.pathSegments.last,
    ]..sort();

    Future<List<String>> everyFile() async => [
      await for (final entity in dir.list())
        if (entity is File) entity.uri.pathSegments.last,
    ]..sort();

    Future<void> expectIndexMatchesDisk(FileExplorerGamesDiskStore s) async {
      final indexed = List.of(await s.debugIndexedFiles())..sort();
      expect(indexed, await filesOnDisk());
      var bytes = 0;
      for (final name in indexed) {
        bytes += await File('${dir.path}/$name').length();
      }
      expect(await s.debugIndexedBytes(), bytes);
    }

    test('pages survive a restart', () async {
      await store().write(key('a'), _page(['a1', 'a2']), now, owner: 'o');

      final reopened = store();
      final found = await reopened.readMany([key('a'), key('b')], owner: 'o');
      expect(found.keys, [key('a')]);
      expect(found[key('a')]!.source, ExplorerGamesSource.disk);
      expect(found[key('a')]!.fetchedAt, now);
      expect(found[key('a')]!.response.data.map((row) => row['id']), [
        'a1',
        'a2',
      ]);
      await expectIndexMatchesDisk(reopened);
      // Nothing half-written is left behind.
      expect(
        (await everyFile()).where((name) => name.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('an expired page is deleted on read and leaves the index', () async {
      final s = store(maxPages: 3);
      final old = now.subtract(
        kExplorerGamesDiskMaxAge + const Duration(hours: 1),
      );
      await s.write(key('old'), _page(['o']), old, owner: 'o');
      await s.write(key('b'), _page(['b']), now, owner: 'o');
      await s.write(key('c'), _page(['c']), now, owner: 'o');

      expect(await s.readMany([key('old')], owner: 'o'), isEmpty);
      await expectIndexMatchesDisk(s);
      expect(await s.debugIndexedFiles(), hasLength(2));

      // Room for one more: nothing live may be evicted to make it.
      await s.write(key('d'), _page(['d']), now, owner: 'o');
      expect(
        (await s.readMany([key('b'), key('c'), key('d')], owner: 'o')).keys,
        [key('b'), key('c'), key('d')],
      );
      await expectIndexMatchesDisk(s);
    });

    test('evicts the least recently used page first', () async {
      final s = store(maxPages: 2);
      await s.write(key('a'), _page(['a']), now, owner: 'o');
      await s.write(key('b'), _page(['b']), now, owner: 'o');
      await s.readMany([key('a')], owner: 'o'); // a is now the most recent
      await s.write(key('c'), _page(['c']), now, owner: 'o');

      final found = await s.readMany([
        key('a'),
        key('b'),
        key('c'),
      ], owner: 'o');
      expect(found.keys, [key('a'), key('c')]);
      await expectIndexMatchesDisk(s);
    });

    test('keeps within its byte budget', () async {
      final probe = store(maxPages: 100);
      await probe.write(key('a'), _page(['a']), now, owner: 'o');
      final one = await probe.debugIndexedBytes();

      final s = store(maxPages: 100, maxBytes: one * 3);
      for (final name in ['a', 'b', 'c', 'd', 'e']) {
        await s.write(key(name), _page([name]), now, owner: 'o');
      }
      expect(await s.debugIndexedBytes(), lessThanOrEqualTo(one * 3));
      await expectIndexMatchesDisk(s);
      expect((await s.readMany([key('d'), key('e')], owner: 'o')).keys, [
        key('d'),
        key('e'),
      ]);
    });

    test('another owner never sees, and wipes, the pages', () async {
      final s = store();
      await s.write(key('a'), _page(['a']), now, owner: 'alice');
      expect(await s.readMany([key('a')], owner: 'bob'), isEmpty);
      expect(await filesOnDisk(), isEmpty);
      expect(await store().readMany([key('a')], owner: 'alice'), isEmpty);
    });

    test('a damaged page is dropped, not shown', () async {
      final s = store();
      await s.write(key('a'), _page(['a']), now, owner: 'o');
      await File('${dir.path}/${key('a')}.json').writeAsString('{not json');

      final reopened = store();
      expect(await reopened.readMany([key('a')], owner: 'o'), isEmpty);
      await expectIndexMatchesDisk(reopened);
      expect(await filesOnDisk(), isEmpty);
    });

    test('a half-written page from a crash is cleaned up', () async {
      await store().write(key('a'), _page(['a']), now, owner: 'o');
      await File('${dir.path}/${key('b')}.json.dead.tmp').writeAsString('{');

      final reopened = store();
      await reopened.readMany([key('a')], owner: 'o');
      await expectIndexMatchesDisk(reopened);
      expect(
        (await everyFile()).where((name) => name.endsWith('.tmp')),
        isEmpty,
      );
    });

    group('a detached board window (read-only)', () {
      test(
        'reads the pages the main window saved, for its owner only',
        () async {
          await store().write(key('a'), _page(['a']), now, owner: 'o');

          final detached = store(readOnly: true);
          final found = await detached.readMany([key('a')], owner: 'o');
          expect(found[key('a')]!.response.data.single['id'], 'a');

          // Another account's window sees nothing, and wipes nothing.
          expect(await detached.readMany([key('a')], owner: 'x'), isEmpty);
          expect(await filesOnDisk(), ['${key('a')}.json']);
        },
      );

      test('never writes, evicts, deletes or clears', () async {
        final old = now.subtract(
          kExplorerGamesDiskMaxAge + const Duration(hours: 1),
        );
        final main = store();
        await main.write(key('old'), _page(['o']), old, owner: 'o');
        await main.write(key('b'), _page(['b']), now, owner: 'o');
        final before = await everyFile();

        final detached = store(readOnly: true, maxPages: 1);
        await detached.write(key('c'), _page(['c']), now, owner: 'o');
        await detached.write(key('d'), _page(['d']), now, owner: 'other');
        // An expired page is not shown, but stays for its writer to drop.
        expect(await detached.readMany([key('old')], owner: 'o'), isEmpty);
        await detached.clear();

        expect(await everyFile(), before);
      });

      test('follows the main window across an account switch', () async {
        final main = store();
        await main.write(key('a'), _page(['a']), now, owner: 'alice');
        final detached = store(readOnly: true);
        expect(
          await detached.readMany([key('a')], owner: 'alice'),
          hasLength(1),
        );

        // The main window signs into another account and saves a page.
        await main.write(key('b'), _page(['b']), now, owner: 'bob');
        expect(await detached.readMany([key('a')], owner: 'alice'), isEmpty);
        expect(await detached.readMany([key('b')], owner: 'bob'), hasLength(1));
      });

      test('a folder the main window never created is simply empty', () async {
        final missing = Directory('${dir.path}/never-created');
        final detached = FileExplorerGamesDiskStore(
          directory: () async => missing,
          readOnly: true,
        );
        expect(await detached.readMany([key('a')], owner: 'o'), isEmpty);
        expect(await missing.exists(), isFalse);
      });
    });
  });

  group('cache with a disk', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('explorer_games_cache');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    FileExplorerGamesDiskStore store({bool readOnly = false}) =>
        FileExplorerGamesDiskStore(
          directory: () async => dir,
          readOnly: readOnly,
        );

    test('a first page fetched in one session paints the next one', () async {
      final repo = _Repo();
      final first = ExplorerGamesCache(
        repository: () => repo,
        disk: store(),
        currentUserId: () => 'u',
      );
      final fetched = await first.fetch(_query(uci: 'd7d6'));
      await first.debugDiskIdle();

      // A new app launch: new cache, new store object, same folder.
      final next = ExplorerGamesCache(
        repository: () => repo,
        disk: store(),
        currentUserId: () => 'u',
      );
      expect(next.peek(_query(uci: 'd7d6')), isNull);
      await next.preload([_query(uci: 'd7d6')]);
      final snapshot = next.peek(_query(uci: 'd7d6'));
      expect(snapshot, isNotNull);
      expect(snapshot!.source, ExplorerGamesSource.disk);
      expect(snapshot.response.data, fetched.data);
      // A saved page is never current: it has no server answer behind it.
      expect(next.isFresh(snapshot.response), isFalse);
      expect(next.isSnapshotFresh(snapshot), isFalse);
      expect(repo.calls, 1);
    });

    test('a detached window paints what the main window saved', () async {
      final repo = _Repo();
      final main = ExplorerGamesCache(
        repository: () => repo,
        disk: store(),
        currentUserId: () => 'u',
      );
      await main.fetch(_query(uci: 'd7d6'));
      await main.debugDiskIdle();

      final detached = ExplorerGamesCache(
        repository: () => repo,
        disk: store(readOnly: true),
        currentUserId: () => 'u',
      );
      final snapshot = await detached.read(_query(uci: 'd7d6'));
      expect(snapshot?.source, ExplorerGamesSource.disk);
      // Its own fetches never touch the folder.
      final filesBefore = await dir.list().length;
      await detached.fetch(_query(uci: 'e7e5'));
      await detached.debugDiskIdle();
      expect(await dir.list().length, filesBefore);
    });

    test('signing out empties memory and disk', () async {
      var user = 'alice';
      final disk = store();
      final cache = ExplorerGamesCache(
        repository: _Repo.new,
        disk: disk,
        currentUserId: () => user,
      );
      await cache.fetch(_query(uci: 'd7d6'));
      await cache.debugDiskIdle();
      expect(await disk.debugIndexedFiles(), hasLength(1));

      user = '';
      cache.handleAccountChange();
      await cache.debugDiskIdle();

      expect(cache.peek(_query(uci: 'd7d6')), isNull);
      expect(await disk.debugIndexedFiles(), isEmpty);
      final pages = [
        await for (final entity in dir.list())
          if (entity.path.endsWith('.json')) entity,
      ];
      expect(pages, isEmpty);
    });

    test("another account never gets the previous account's pages", () async {
      var user = 'alice';
      final cache = ExplorerGamesCache(
        repository: _Repo.new,
        disk: store(),
        currentUserId: () => user,
      );
      await cache.fetch(_query(uci: 'd7d6'));
      await cache.debugDiskIdle();

      // No auth event at all: the next call notices the account itself.
      user = 'bob';
      expect(cache.peek(_query(uci: 'd7d6')), isNull);
      await cache.preload([_query(uci: 'd7d6')]);
      expect(cache.peek(_query(uci: 'd7d6')), isNull);

      final relaunch = ExplorerGamesCache(
        repository: _Repo.new,
        disk: store(),
        currentUserId: () => 'bob',
      );
      await relaunch.preload([_query(uci: 'd7d6')]);
      expect(relaunch.peek(_query(uci: 'd7d6')), isNull);
    });

    test(
      'a page fetched for the old account is not saved for the new one',
      () async {
        var user = 'alice';
        final repo = _Repo()..gate = Completer<void>();
        final disk = store();
        final cache = ExplorerGamesCache(
          repository: () => repo,
          disk: disk,
          currentUserId: () => user,
        );
        final pending = cache.fetch(_query(uci: 'd7d6'));
        user = 'bob';
        cache.handleAccountChange();
        repo.gate!.complete();
        await pending;
        await cache.debugDiskIdle();

        expect(cache.peek(_query(uci: 'd7d6')), isNull);
        expect(await disk.debugIndexedFiles(), isEmpty);
      },
    );
  });
}
