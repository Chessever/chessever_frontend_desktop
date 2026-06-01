import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('TWIC all-games stats ignores visible-list filters', () async {
    const playerId = '00000000-0000-4000-8000-000000000001';
    const playerKey = PlayerProfileKey(
      fideId: 1503014,
      playerName: 'Carlsen, Magnus',
      source: PlayerProfileDataSource.twic,
      gamebasePlayerId: playerId,
    );
    final repository = _RecordingGamebaseRepository(playerId: playerId);
    final container = ProviderContainer(
      overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    final visibleGames = container.read(
      playerProfileGamesKeyProvider(playerKey).notifier,
    );
    visibleGames.mergeFilter(
      color: GameColorFilter.white,
      eco: GameEcoFilter.forCode('C65'),
      online: GameOnlineFilter.online,
      playerResultFilter: PlayerResultFilter.win,
      result: GameResultFilter.whiteWins,
      searchQuery: 'event:visible-page-only',
      timeControl: GameTimeControlFilter.blitz,
    );

    final statsProvider = twicPlayerStatsProvider(
      const TwicPlayerStatsRequest(
        playerKey: playerKey,
        scope: TwicStatsScope.allGames,
      ),
    );
    final subscription = container.listen(statsProvider, (_, _) {});
    addTearDown(subscription.close);

    final analytics = await container.read(statsProvider.future);

    expect(analytics?.resultStats.totalGames, 1234);
    expect(repository.statsRequests, hasLength(1));
    expect(repository.statsRequests.single.q, isNull);
    expect(repository.statsRequests.single.color, 'all');
    expect(repository.statsRequests.single.timeControl, isNull);
    expect(repository.statsRequests.single.outcome, isNull);
    expect(repository.statsRequests.single.eco, isNull);
    expect(repository.statsRequests.single.dateFrom, isNull);
    expect(repository.statsRequests.single.dateTo, isNull);
    expect(repository.statsRequests.single.ratingFrom, isNull);
    expect(repository.statsRequests.single.ratingTo, isNull);
    expect(repository.statsRequests.single.isOnline, isNull);

    container
        .read(playerProfileGamesKeyProvider(playerKey).notifier)
        .setSearchQuery('event:changed-after-stats-read');
    await container.pump();

    expect(repository.statsRequests, hasLength(1));
  });
}

class _RecordingGamebaseRepository extends GamebaseRepository {
  _RecordingGamebaseRepository({required this.playerId}) : super(Dio());

  final String playerId;
  final statsRequests = <_StatsRequest>[];

  @override
  Future<GamebasePlayer?> getPlayerById(String id) async {
    if (id != playerId) return null;
    return const GamebasePlayer(
      id: '00000000-0000-4000-8000-000000000001',
      fideId: '1503014',
      name: 'Carlsen, Magnus',
      gender: PlayerGender.male,
      fed: 'NOR',
      title: 'GM',
      ratingClassical: 2830,
    );
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
    return const {
      'data': <Map<String, dynamic>>[],
      'metadata': {'hasMore': false, 'totalCount': 1234},
    };
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
    statsRequests.add(
      _StatsRequest(
        q: q,
        color: color,
        timeControl: timeControl,
        outcome: outcome,
        eco: eco,
        dateFrom: dateFrom,
        dateTo: dateTo,
        ratingFrom: ratingFrom,
        ratingTo: ratingTo,
        isOnline: isOnline,
      ),
    );
    return const {
      'data': {
        'totals': {'games': 1234, 'wins': 600, 'draws': 400, 'losses': 234},
        'color': {
          'white': {'games': 620, 'wins': 320, 'draws': 210, 'losses': 90},
          'black': {'games': 614, 'wins': 280, 'draws': 190, 'losses': 144},
        },
        'openings': {
          'all': [
            {
              'eco': 'C65',
              'openingName': 'Ruy Lopez',
              'games': 200,
              'wins': 100,
              'draws': 70,
              'losses': 30,
            },
          ],
          'white': <Map<String, dynamic>>[],
          'black': <Map<String, dynamic>>[],
        },
        'avgOpponentRating': 2710,
      },
    };
  }
}

class _StatsRequest {
  const _StatsRequest({
    required this.q,
    required this.color,
    required this.timeControl,
    required this.outcome,
    required this.eco,
    required this.dateFrom,
    required this.dateTo,
    required this.ratingFrom,
    required this.ratingTo,
    required this.isOnline,
  });

  final String? q;
  final String color;
  final String? timeControl;
  final String? outcome;
  final String? eco;
  final String? dateFrom;
  final String? dateTo;
  final int? ratingFrom;
  final int? ratingTo;
  final bool? isOnline;
}
