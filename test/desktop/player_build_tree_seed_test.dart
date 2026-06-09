import 'dart:async';

import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _startingFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class _AggregateCall {
  const _AggregateCall({
    required this.fen,
    required this.moves,
    this.playerId,
    this.timeControl,
    this.minRating,
    this.maxRating,
    this.color,
    this.result,
    this.yearFrom,
    this.yearTo,
    this.isOnline,
  });

  final String fen;
  final List<String> moves;
  final String? playerId;
  final TimeControl? timeControl;
  final int? minRating;
  final int? maxRating;
  final String? color;
  final String? result;
  final int? yearFrom;
  final int? yearTo;
  final bool? isOnline;
}

class _CapturingGamebaseRepository extends GamebaseRepository {
  _CapturingGamebaseRepository() : super(Dio(), baseUrl: 'http://localhost');

  final aggregateCalls = <_AggregateCall>[];
  final playerGameColors = <String>[];
  final playerGamePages = <int>[];
  Completer<void>? firstFetchStarted;
  Completer<void>? allowFirstFetchReturn;
  bool twoWhitePages = false;
  var _pausedFirstFetch = false;

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
    aggregateCalls.add(
      _AggregateCall(
        fen: fen,
        moves: List<String>.from(moves),
        playerId: playerId,
        timeControl: timeControl,
        minRating: minRating,
        maxRating: maxRating,
        color: color,
        result: result,
        yearFrom: yearFrom,
        yearTo: yearTo,
        isOnline: isOnline,
      ),
    );

    return const GamebaseResponse(
      status: 'success',
      data: GamebaseData(moves: []),
    );
  }

  @override
  Future<Map<String, dynamic>> getPlayerStats({
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
  }) async {
    return {
      'data': {
        'totals': {'games': 2},
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
    playerGameColors.add(color);
    playerGamePages.add(pageNumber);
    if (!_pausedFirstFetch && firstFetchStarted != null) {
      _pausedFirstFetch = true;
      firstFetchStarted!.complete();
      await allowFirstFetchReturn?.future;
    }
    final pgnColor = color == 'black' ? '0-1' : '1-0';
    final hasMore = twoWhitePages && color == 'white' && pageNumber == 0;
    final totalCount =
        color == 'white' && twoWhitePages
            ? 2
            : color == 'all'
            ? 2
            : 1;
    return {
      'data': [
        {
          'id': 'game-$color-$pageNumber',
          'date': '2024-01-01',
          'result': pgnColor,
          'whitePlayerId': color == 'black' ? 'other' : playerId,
          'blackPlayerId': color == 'black' ? playerId : 'other',
          'pgn': '''
[Event "Test"]
[Site "Local"]
[Date "2024.01.01"]
[White "White"]
[Black "Black"]
[Result "$pgnColor"]

1. e4 e5 $pgnColor
''',
        },
      ],
      'metadata': {'hasMore': hasMore, 'totalCount': totalCount},
    };
  }
}

void main() {
  test(
    'player build-tree seed scopes aggregate query to player games',
    () async {
      final repository = _CapturingGamebaseRepository();
      final container = ProviderContainer(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        gamebaseExplorerProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      const playerId = 'player-uuid';
      const player = GamebasePlayer(
        id: playerId,
        fideId: '1503014',
        name: 'Carlsen, Magnus',
        gender: PlayerGender.male,
        fed: 'NOR',
        title: 'GM',
        ratingClassical: 2830,
      );
      const scopedFilters = GamebaseFilters(
        playerIds: [playerId],
        selectedPlayers: [player],
        timeControls: [TimeControl.blitz],
        minRating: 2400,
        maxRating: 2900,
        playerColor: GamebasePlayerColor.white,
        gameResult: GamebaseGameResult.whiteWins,
        yearFrom: 2019,
        yearTo: 2025,
        isOnline: true,
      );

      final notifier = container.read(gamebaseExplorerProvider.notifier);
      notifier.updateFilters(scopedFilters);
      notifier.setPositionWithMoves(_startingFen, const <String>[]);
      await notifier.refresh();

      expect(repository.aggregateCalls, isNotEmpty);
      final call = repository.aggregateCalls.last;
      expect(call.fen, _startingFen);
      expect(call.moves, isEmpty);
      expect(call.playerId, player.id);
      expect(call.timeControl, TimeControl.blitz);
      expect(call.minRating, 2400);
      expect(call.maxRating, 2900);
      expect(call.color, 'white');
      expect(call.result, 'W');
      expect(call.yearFrom, 2019);
      expect(call.yearTo, 2025);
      expect(call.isOnline, isTrue);
    },
  );

  for (final entry in const [
    (GamebasePlayerColor.white, ['white', 'black']),
    (GamebasePlayerColor.black, ['black', 'white']),
    (null, ['all']),
  ]) {
    test(
      'local player tree fetches ${entry.$1?.name ?? 'both'} side first',
      () async {
        final repository = _CapturingGamebaseRepository();
        final container = ProviderContainer(
          overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(
          gamebaseExplorerProvider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        const playerId = 'player-uuid';
        const player = GamebasePlayer(
          id: playerId,
          fideId: '1503014',
          name: 'Carlsen, Magnus',
          gender: PlayerGender.male,
          fed: 'NOR',
          title: 'GM',
          ratingClassical: 2830,
        );
        final notifier = container.read(gamebaseExplorerProvider.notifier);
        notifier.updateFilters(
          GamebaseFilters(
            playerIds: const [playerId],
            selectedPlayers: const [player],
            playerColor: entry.$1,
          ),
        );
        notifier.enableLocalPlayerTree(playerId);

        container.read(playerOpeningTreeProvider(playerId).notifier).start();
        await _waitForTreeComplete(container, playerId);

        expect(repository.playerGameColors, entry.$2);
        final progress =
            container.read(playerOpeningTreeProvider(playerId)).progress;
        if (entry.$1 == null) {
          expect(progress.priorityColor, isNull);
          expect(progress.priorityFetchedGames, 1);
          expect(progress.priorityTotalGames, 2);
        } else {
          expect(progress.priorityColor, entry.$1!.name);
          expect(progress.priorityFetchedGames, 1);
          expect(progress.priorityTotalGames, 1);
        }
      },
    );
  }

  test('local player tree reprioritizes fetches when color changes', () async {
    final repository =
        _CapturingGamebaseRepository()
          ..twoWhitePages = true
          ..firstFetchStarted = Completer<void>()
          ..allowFirstFetchReturn = Completer<void>();
    final container = ProviderContainer(
      overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      gamebaseExplorerProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    const playerId = 'player-uuid';
    const player = GamebasePlayer(
      id: playerId,
      fideId: '1503014',
      name: 'Carlsen, Magnus',
      gender: PlayerGender.male,
      fed: 'NOR',
      title: 'GM',
      ratingClassical: 2830,
    );
    final notifier = container.read(gamebaseExplorerProvider.notifier);
    notifier.updateFilters(
      const GamebaseFilters(
        playerIds: [playerId],
        selectedPlayers: [player],
        playerColor: GamebasePlayerColor.white,
      ),
    );
    notifier.enableLocalPlayerTree(playerId);

    container.read(playerOpeningTreeProvider(playerId).notifier).start();
    await repository.firstFetchStarted!.future;
    notifier.updateFilters(
      const GamebaseFilters(
        playerIds: [playerId],
        selectedPlayers: [player],
        playerColor: GamebasePlayerColor.black,
      ),
    );
    repository.allowFirstFetchReturn!.complete();
    await _waitForTreeComplete(container, playerId);

    expect(repository.playerGameColors, ['white', 'black', 'white']);
    expect(repository.playerGamePages, [0, 0, 1]);
    final progress =
        container.read(playerOpeningTreeProvider(playerId)).progress;
    expect(progress.priorityColor, 'black');
    expect(progress.priorityFetchedGames, 1);
    expect(progress.priorityTotalGames, 1);
  });
}

Future<void> _waitForTreeComplete(
  ProviderContainer container,
  String playerId,
) async {
  for (var i = 0; i < 60; i++) {
    final state = container.read(playerOpeningTreeProvider(playerId));
    if (state.progress.status == PlayerOpeningTreeStatus.complete) return;
    if (state.progress.status == PlayerOpeningTreeStatus.error) {
      fail(state.progress.error ?? 'tree build failed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('tree build did not complete');
}
