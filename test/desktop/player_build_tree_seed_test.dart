import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:dartchess/dartchess.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('player tree controller builds from backend snapshot', () async {
    final repository = _BackendTreeRepository();
    final container = ProviderContainer(
      overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    container.read(playerOpeningTreeProvider('player-uuid').notifier).start();
    await _waitForTreeComplete(container, 'player-uuid');

    expect(repository.buildForceRebuildValues, [false]);
    expect(repository.statusTreeIds, ['v2:player-uuid:40']);
    expect(repository.downloadTreeIds, ['v2:player-uuid:40']);

    final state = container.read(playerOpeningTreeProvider('player-uuid'));
    expect(state.treeId, 'v2:player-uuid:40');
    expect(state.index.movesForFen(Chess.initial.fen).single.uci, 'e2e4');
    await _waitForGamesIndexed(container, 'player-uuid');
    expect(repository.playerGamesPages, [0]);
    expect(
      container
          .read(playerOpeningTreeProvider('player-uuid'))
          .index
          .downloadedGameCount,
      1,
    );
  });

  test('retry still reuses backend tree instead of forcing rebuild', () async {
    final repository = _BackendTreeRepository();
    final container = ProviderContainer(
      overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(
      playerOpeningTreeProvider('player-uuid').notifier,
    );
    notifier.start();
    await _waitForTreeComplete(container, 'player-uuid');

    notifier.retry();
    await _waitForBuildCount(repository, 2);
    await _waitForTreeComplete(container, 'player-uuid');

    expect(repository.buildForceRebuildValues, [false, false]);
  });

  test(
    'completes when tree download is ready before status says ready',
    () async {
      final repository = _BackendTreeRepository()..statusValue = 'building';
      final container = ProviderContainer(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      container.read(playerOpeningTreeProvider('player-uuid').notifier).start();
      await _waitForTreeComplete(container, 'player-uuid');

      expect(repository.statusTreeIds, ['v2:player-uuid:40']);
      expect(repository.downloadTreeIds, ['v2:player-uuid:40']);
    },
  );
}

class _BackendTreeRepository extends GamebaseRepository {
  _BackendTreeRepository() : super(Dio(), baseUrl: 'http://localhost');

  final buildForceRebuildValues = <bool>[];
  final statusTreeIds = <String>[];
  final downloadTreeIds = <String>[];
  final playerGamesPages = <int>[];
  String statusValue = 'ready';

  @override
  Future<Map<String, dynamic>> startPlayerOpeningTreeBuild({
    required String playerId,
    int maxPly = 40,
    bool forceRebuild = false,
  }) async {
    buildForceRebuildValues.add(forceRebuild);
    return {
      'status': 'success',
      'data': {
        'treeId': 'v2:$playerId:$maxPly',
        'status': 'queued',
        'maxPly': maxPly,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getPlayerOpeningTreeStatus({
    required String playerId,
    required String treeId,
  }) async {
    statusTreeIds.add(treeId);
    return {
      'status': 'success',
      'data': {'treeId': treeId, 'status': statusValue},
    };
  }

  @override
  Future<Map<String, dynamic>?> getPlayerOpeningTree({
    required String playerId,
    required String treeId,
  }) async {
    downloadTreeIds.add(treeId);
    return {
      'status': 'success',
      'data': {
        'treeId': treeId,
        'playerId': playerId,
        'maxPly': 40,
        'rootNodeId': 0,
        'generatedAt': '2026-06-12T00:00:00.000Z',
        'nodes': [
          {
            'id': 0,
            'fenKey': 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -',
            'ply': 0,
            'moves': [
              {
                'uci': 'e2e4',
                'childNodeId': 1,
                'white': 1,
                'black': 0,
                'draws': 0,
                'total': 1,
                'filterBuckets': <String, dynamic>{},
              },
            ],
          },
        ],
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getPlayerGames({
    required String playerId,
    String? q,
    String color = 'all',
    String? timeControl,
    String? outcome,
    String? eco,
    String? opening,
    String? variation,
    String? event,
    String? site,
    String? dateFrom,
    String? dateTo,
    String? opponentId,
    int? ratingFrom,
    int? ratingTo,
    bool? isOnline,
    int pageNumber = 0,
    int pageSize = 100,
  }) async {
    playerGamesPages.add(pageNumber);
    return {
      'data': [
        {
          'id': 'game-$pageNumber',
          'date': '2024-01-01',
          'result': '1-0',
          'whitePlayerId': playerId,
          'blackPlayerId': 'other',
          'white': 'White',
          'black': 'Black',
          'pgn': '''
[Event "Test"]
[Site "Local"]
[Date "2024.01.01"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 1-0
''',
        },
      ],
      'metadata': {'hasMore': false, 'totalCount': 1},
    };
  }
}

Future<void> _waitForBuildCount(
  _BackendTreeRepository repository,
  int count,
) async {
  for (var i = 0; i < 40; i++) {
    if (repository.buildForceRebuildValues.length >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('expected $count backend build calls');
}

Future<void> _waitForTreeComplete(
  ProviderContainer container,
  String playerId,
) async {
  for (var i = 0; i < 40; i++) {
    final state = container.read(playerOpeningTreeProvider(playerId));
    if (state.progress.status == PlayerOpeningTreeStatus.complete) return;
    if (state.progress.status == PlayerOpeningTreeStatus.error) {
      fail(state.progress.error ?? 'tree build failed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('tree build did not complete');
}

Future<void> _waitForGamesIndexed(
  ProviderContainer container,
  String playerId,
) async {
  for (var i = 0; i < 40; i++) {
    final state = container.read(playerOpeningTreeProvider(playerId));
    if (state.index.downloadedGameCount > 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('tree games did not index');
}
