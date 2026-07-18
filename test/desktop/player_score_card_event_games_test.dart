import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/player_score_card_view.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  test('tournament scorecards never watch every tournament game', () {
    final source =
        File(
          'lib/desktop/widgets/player_score_card_view.dart',
        ).readAsStringSync();

    expect(source, isNot(contains('ref.watch(mergedTournamentGamesProvider)')));
    expect(source, isNot(contains('ref.watch(gamesTourScreenProvider)')));
  });

  test('mixed FIDE and legacy-name rows retain every player round', () {
    final fideRound = _game('round-2-game', 'round-2');
    final legacyRound = _game('round-1-game', 'round-1');
    final duplicate = _game('round-2-game', 'round-2');

    final merged = mergeEventPlayerGameQueryResults(
      byFide: <Games>[fideRound],
      byName: <Games>[legacyRound, duplicate],
    );

    expect(merged.map((game) => game.id), <String>[
      'round-1-game',
      'round-2-game',
    ]);
  });

  test('scorecard provider keys keep an immutable canonical tour scope', () {
    final additionalTourIds = <String>[' tour-b ', 'tour-a', ''];
    final key = EventPlayerGamesKey(
      tourId: 'tour-a',
      additionalTourIds: additionalTourIds,
      playerName: 'Player, Exact',
    );

    additionalTourIds.add('tour-c');

    expect(key.tourIds, <String>['tour-a', 'tour-b']);
    expect(() => key.additionalTourIds.add('tour-c'), throwsUnsupportedError);
  });

  test(
    'scorecard queries only the selected player while retaining all rounds',
    () async {
      final repository = _ScorecardRepository(<Games>[
        _game('round-1-game', 'round-1'),
        _game('round-2-game', 'round-2'),
        _game('armageddon-game', 'armageddon'),
      ]);
      final container = ProviderContainer(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final key = EventPlayerGamesKey(
        tourId: 'huge-event',
        playerName: 'Player, Exact',
        fideId: 1234,
      );
      final games = await container.read(eventPlayerGamesProvider(key).future);

      expect(repository.calls, <EventPlayerGamesKey>[key]);
      expect(games.map((game) => game.gameId), <String>[
        'round-1-game',
        'round-2-game',
        'armageddon-game',
      ]);
    },
  );

  test(
    'pagination-style event scope includes every sibling but no other category',
    () {
      final tourIds = resolveEventPlayerTourIds(
        selectedTourId: 'open-boards-67-126',
        selectedTourName: 'European Open Boards 67-126',
        eventTours: const <({String id, String name})>[
          (id: 'women-boards-1-50', name: 'European Women Boards 1-50'),
          (id: 'open-boards-1-66', name: 'European Open Boards 1-66'),
          (id: 'open-boards-67-126', name: 'European Open Boards 67-126'),
          (id: 'open-blitz', name: 'European Open Blitz'),
        ],
      );

      expect(tourIds, <String>['open-boards-67-126', 'open-boards-1-66']);
    },
  );

  test(
    'one scorecard provider merges exact player rows across sibling tours',
    () async {
      final repository = _ScorecardRepository.byTour(<String, List<Games>>{
        'open-boards-67-126': <Games>[
          _game('round-2-game', 'round-2', tourId: 'open-boards-67-126'),
        ],
        'open-boards-1-66': <Games>[
          _game('round-1-game', 'round-1', tourId: 'open-boards-1-66'),
        ],
        'unrelated-category': <Games>[
          _game('unrelated-game', 'round-1', tourId: 'unrelated-category'),
        ],
      });
      final container = ProviderContainer(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final key = EventPlayerGamesKey(
        tourId: 'open-boards-67-126',
        additionalTourIds: <String>['open-boards-1-66'],
        playerName: 'Player, Exact',
        fideId: 1234,
      );
      final games = await container.read(eventPlayerGamesProvider(key).future);

      expect(repository.calls.map((call) => call.tourId), <String>[
        'open-boards-67-126',
        'open-boards-1-66',
      ]);
      expect(games.map((game) => game.gameId), <String>[
        'round-2-game',
        'round-1-game',
      ]);
      expect(games.map((game) => game.tourId), <String>[
        'open-boards-67-126',
        'open-boards-1-66',
      ]);
    },
  );

  test('active scorecard safety refresh keeps live results current', () async {
    final repository = _ScorecardRepository(<Games>[
      _game('round-1-game', 'round-1', status: 'live'),
    ]);
    final container = ProviderContainer(
      overrides: [gameRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    final key = EventPlayerGamesKey(
      tourId: 'huge-event',
      playerName: 'Player, Exact',
      fideId: 1234,
    );
    final subscription = container.listen(
      eventPlayerGamesProvider(key),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(eventPlayerGamesProvider(key).future);

    repository.games = <Games>[_game('round-1-game', 'round-1', status: '1-0')];
    final refreshed =
        await container.read(eventPlayerGamesProvider(key).notifier).refresh();

    expect(refreshed, isTrue);
    expect(
      container
          .read(eventPlayerGamesProvider(key))
          .valueOrNull!
          .single
          .gameStatus,
      GameStatus.whiteWins,
    );
  });

  test('hidden scorecards retain rows but suspend safety polling', () async {
    final repository = _ScorecardRepository(<Games>[
      _game('round-1-game', 'round-1', status: 'live'),
    ]);
    final container = ProviderContainer(
      overrides: [gameRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final tabs = container.read(desktopTabsProvider.notifier);
    final ownerId = tabs.open(TabKind.playerScoreCard, reuseExisting: false);
    final key = EventPlayerGamesKey(
      tourId: 'huge-event',
      playerName: 'Player, Exact',
      fideId: 1234,
      ownerId: ownerId,
    );
    final subscription = container.listen(
      eventPlayerGamesProvider(key),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(eventPlayerGamesProvider(key).future);
    final notifier = container.read(eventPlayerGamesProvider(key).notifier);

    expect(notifier.safetyRefreshScheduled, isTrue);
    expect(repository.calls, hasLength(1));

    tabs.open(TabKind.library, reuseExisting: false);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.safetyRefreshScheduled, isFalse);
    expect(await notifier.refresh(), isFalse);
    expect(repository.calls, hasLength(1));
    expect(
      container.read(eventPlayerGamesProvider(key)).valueOrNull,
      hasLength(1),
    );

    repository.games = <Games>[_game('round-1-game', 'round-1', status: '0-1')];
    tabs.activate(ownerId);
    for (var attempt = 0; attempt < 10; attempt++) {
      await container.pump();
      final status =
          container
              .read(eventPlayerGamesProvider(key))
              .valueOrNull
              ?.single
              .gameStatus;
      if (status == GameStatus.blackWins) break;
    }

    expect(repository.calls, hasLength(2));
    expect(notifier.safetyRefreshScheduled, isTrue);
    expect(
      container
          .read(eventPlayerGamesProvider(key))
          .valueOrNull!
          .single
          .gameStatus,
      GameStatus.blackWins,
    );
  });

  test('one malformed legacy row does not discard valid player rounds', () {
    final converted = convertEventPlayerGameRows(<Games>[
      _game('round-1-game', 'round-1'),
      _malformedGame('broken-game', 'round-2'),
      _game('round-3-game', 'round-3'),
    ]);

    expect(converted.map((game) => game.gameId), <String>[
      'round-1-game',
      'round-3-game',
    ]);
  });
}

class _ScorecardRepository implements GameRepository {
  _ScorecardRepository(this.games) : gamesByTour = null;

  _ScorecardRepository.byTour(this.gamesByTour) : games = const <Games>[];

  List<Games> games;
  final Map<String, List<Games>>? gamesByTour;
  final List<EventPlayerGamesKey> calls = <EventPlayerGamesKey>[];

  @override
  Future<List<Games>> getEventGamesByPlayer({
    required String tourId,
    int? fideId,
    required String playerName,
  }) async {
    calls.add(
      EventPlayerGamesKey(
        tourId: tourId,
        playerName: playerName,
        fideId: fideId,
      ),
    );
    return gamesByTour?[tourId] ?? games;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected repository call: $invocation');
  }
}

Games _game(
  String id,
  String roundId, {
  String status = '1-0',
  String tourId = 'huge-event',
}) {
  return Games(
    id: id,
    roundId: roundId,
    roundSlug: roundId,
    tourId: tourId,
    tourSlug: tourId,
    players: <Player>[
      Player(
        name: 'Player, Exact',
        title: 'GM',
        rating: 2600,
        fideId: 1234,
        fed: 'TUR',
        clock: 0,
        team: '',
      ),
      Player(
        name: 'Opponent, One',
        title: 'IM',
        rating: 2500,
        fideId: 5678,
        fed: 'USA',
        clock: 0,
        team: '',
      ),
    ],
    status: status,
    boardNr: 1,
  );
}

Games _malformedGame(String id, String roundId) {
  return Games(
    id: id,
    roundId: roundId,
    roundSlug: roundId,
    tourId: 'huge-event',
    tourSlug: 'huge-event',
    players: <Player>[
      Player(
        name: 'Player, Exact',
        title: 'GM',
        rating: 2600,
        fideId: 1234,
        fed: 'TUR',
        clock: 0,
        team: '',
      ),
    ],
    status: 'live',
    boardNr: 2,
  );
}
