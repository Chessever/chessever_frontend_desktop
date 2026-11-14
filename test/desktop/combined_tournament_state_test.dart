import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/combined/combined_hall_provider.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/repository/supabase/round/round_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:flutter/material.dart';
import 'package:chessever/desktop/widgets/tournament_category_switcher.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/screens/group_event/model/about_tour_model.dart';
import 'package:chessever/screens/group_event/model/tour_detail_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/live_tour_id_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/state/combined_tournament.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/services/desktop_web_location.dart';
import 'package:chessever/desktop/panes/tournament_detail_pane.dart'
    show tournamentDetailGamesSearchByTabIdProvider;
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/round/round.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/live_rounds_id_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';

class MemoryStore implements CombinedTournamentStore {
  final values = <String, bool>{};
  Completer<bool?>? gate;
  @override
  Future<bool?> read(String eventId) async =>
      gate == null ? values[eventId] : gate!.future;
  @override
  Future<void> write(String eventId, bool selected) async {
    values[eventId] = selected;
  }
}

final _time = DateTime.utc(2026, 11, 11, 16);
Games _row(
  String id,
  String tour, {
  bool live = false,
  String white = 'White',
}) => Games(
  id: id,
  tourId: tour,
  tourSlug: tour,
  roundId: '$tour-r',
  roundSlug: 'round-1',
  boardNr: 1,
  status: live ? '*' : '1-0',
  lastMove: 'e2e4',
  players: [
    Player(
      name: '$white $id',
      title: 'GM',
      rating: 2700,
      fed: 'USA',
      clock: 60000,
      fideId: 1,
      team: '',
    ),
    Player(
      name: 'Black $id',
      title: 'GM',
      rating: 2600,
      fed: 'NOR',
      clock: 60000,
      fideId: 2,
      team: '',
    ),
  ],
);
GamesTourModel _game(
  String id,
  String tour, {
  bool live = false,
  String white = 'White',
}) => GamesTourModel.fromGame(_row(id, tour, live: live, white: white));
Round _round(String tour) => Round(
  id: '$tour-r',
  name: 'Round 1',
  slug: 'round-1',
  tourId: tour,
  tourSlug: tour,
  createdAt: _time,
  startsAt: _time,
  url: '',
);
final _categories = CombinedCategories([
  const CombinedCategory(tourId: 'a', label: 'Group A', avgElo: 2700, order: 0),
  const CombinedCategory(tourId: 'b', label: 'Group B', avgElo: 2600, order: 1),
]);
final _event = GroupBroadcast(
  id: 'event',
  name: 'Festival',
  createdAt: _time,
  search: const [],
);

ProviderContainer _container({
  MemoryStore? store,
  GameDisplayMode display = GameDisplayMode.all,
  bool failB = false,
  bool pendingB = false,
}) => ProviderContainer(
  overrides: [
    combinedTournamentStoreProvider.overrideWithValue(store ?? MemoryStore()),
    combinedTournamentCategoriesProvider.overrideWithValue(_categories),
    selectedBroadcastModelProvider.overrideWith((ref) => _event),
    combinedHallProvider.overrideWith(
      (ref, ids) => CombinedHall(
        ref,
        ids,
        backgroundDelay: Duration.zero,
        publishDelay: Duration.zero,
        readSource: (id) async {
          if (pendingB && id == 'b') return Completer<List<Round>>().future;
          if (failB && id == 'b') throw StateError('offline');
          return [_round(id)];
        },
        readPage:
            (round, offset, limit) async =>
                offset > 0
                    ? []
                    : [
                      _row(
                        '${round.tourId}-1',
                        round.tourId,
                        live: round.tourId == 'b',
                        white: round.tourId == 'b' ? 'Magnus' : 'White',
                      ),
                      _row('${round.tourId}-2', round.tourId),
                      _row('${round.tourId}-3', round.tourId),
                    ],
      ),
    ),
    liveRoundsIdProvider.overrideWith((ref) => Stream.value(const [])),
    combinedTournamentDisplayModeProvider.overrideWith((ref) => display),
  ],
);

Future<void> _settleHall() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  test(
    'a focused board expands a single-source hall preview to the full Combined rail',
    () async {
      final full = [
        for (final id in ['a', 'b'])
          TournamentGameSummary.fromGamesTourModel(_game('$id-1', id)),
      ];
      var requests = 0;
      final c = ProviderContainer(
        overrides: [
          selectedBroadcastModelProvider.overrideWith((ref) => _event),
          combinedTournamentCategoriesProvider.overrideWithValue(_categories),
          combinedTournamentStoreProvider.overrideWithValue(MemoryStore()),
          combinedTournamentLinkProvider.overrideWith((ref, id) async {
            requests++;
            return CombinedTournamentLinkData(eventId: 'event', games: full);
          }),
        ],
      );
      addTearDown(c.dispose);
      final game = _game('a-1', 'a');
      final preview = buildTournamentBoardTabArgs(
        game,
        'Festival',
        eventGames: [game],
      );
      expect(await completeCombinedBoardNavigation(c, preview), same(preview));
      expect(requests, 0);
      await c
          .read(combinedTournamentSelectionProvider.notifier)
          .select('event', true);
      final expanded = await completeCombinedBoardNavigation(c, preview);
      expect(expanded.eventGames.map((g) => g.id), ['a-1', 'b-1']);
      expect(expanded.gameId, 'a-1');
      expect(expanded.eventGamesKey, isNull);
      expect(requests, 1);
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Combined is free and remembered per event, across sessions', () async {
    final store = MemoryStore();
    final first = _container(store: store);
    addTearDown(first.dispose);
    await first
        .read(combinedTournamentSelectionProvider.notifier)
        .select('event', true);
    expect(first.read(combinedTournamentSelectedProvider), isTrue);
    final second = _container(store: store);
    addTearDown(second.dispose);
    await second
        .read(combinedTournamentSelectionProvider.notifier)
        .ensureLoaded('event');
    expect(second.read(combinedTournamentSelectedProvider), isTrue);
    await second
        .read(combinedTournamentSelectionProvider.notifier)
        .select('other', true);
    await second
        .read(combinedTournamentSelectionProvider.notifier)
        .select('event', false);
    expect(second.read(combinedTournamentSelectedProvider), isFalse);
    expect(second.read(combinedTournamentSelectionProvider), {'other'});
  });

  test('a late disk read cannot overwrite the current selection', () async {
    final store = MemoryStore()..gate = Completer<bool?>();
    final selection = CombinedTournamentSelection(store);
    addTearDown(selection.dispose);
    final pending = selection.ensureLoaded('event');
    await selection.select('event', false);
    store.gate!.complete(true);
    await pending;
    expect(selection.state, isEmpty);
  });

  test(
    'shared native/browser data keeps separate source sections and searches all categories',
    () async {
      final c = _container();
      addTearDown(c.dispose);
      final subscription = c.listen(
        combinedTournamentDataProvider('tab'),
        (_, __) {},
      );
      addTearDown(subscription.close);
      await _settleHall();
      var data = c.read(combinedTournamentDataProvider('tab'));
      expect(data.grouped.allGames.map((game) => game.tourId), [
        'a',
        'a',
        'a',
        'b',
        'b',
        'b',
      ]);
      expect(data.buckets, hasLength(1));
      expect(data.buckets.single.sources.map((source) => source.label), [
        'Group A',
        'Group B',
      ]);
      expect(data.buckets.single.round.sourceRoundIds, ['a-r', 'b-r']);
      c.read(tournamentDetailGamesSearchByTabIdProvider('tab').notifier).state =
          'magnus';
      data = c.read(combinedTournamentDataProvider('tab'));
      expect(data.buckets.single.games.map((game) => game.gameId), ['b-1']);
      expect(data.buckets.single.sources.single.label, 'Group B');
      expect(data.grouped.allGames, hasLength(6));
      expect(
        c
            .read(combinedTournamentDataProvider('different-tab'))
            .buckets
            .single
            .games,
        hasLength(6),
      );
    },
  );

  test(
    'Combined waits for every category schedule instead of painting one '
    'category and regrouping when the next arrives',
    () async {
      final c = _container(pendingB: true);
      addTearDown(c.dispose);
      final sub = c.listen(combinedTournamentDataProvider('tab'), (_, __) {});
      addTearDown(sub.close);
      await _settleHall();
      final data = c.read(combinedTournamentDataProvider('tab'));
      expect(data.grouped.isLoading, isTrue);
      expect(data.buckets, isEmpty);
      expect(data.grouped.allGames, isEmpty);
    },
  );

  test(
    'Live filters every source and a failed category does not hide the rest',
    () async {
      final c = _container(display: GameDisplayMode.hideFinishedGames);
      addTearDown(c.dispose);
      final sub = c.listen(combinedTournamentDataProvider('tab'), (_, __) {});
      addTearDown(sub.close);
      await _settleHall();
      final data = c.read(combinedTournamentDataProvider('tab'));
      expect(data.buckets.single.games.map((game) => game.gameId), ['b-1']);
      final partial = _container(failB: true);
      addTearDown(partial.dispose);
      final partialSub = partial.listen(
        combinedTournamentDataProvider('tab'),
        (_, __) {},
      );
      addTearDown(partialSub.close);
      await _settleHall();
      final retained = partial.read(combinedTournamentDataProvider('tab'));
      expect(retained.grouped.loadError, isNull);
      expect(retained.buckets.single.sources.single.label, 'Group A');
    },
  );

  test(
    'keyboard movement respects odd-sized source grids and event ids scope folding',
    () {
      final sources = [
        for (final id in ['a', 'b'])
          GamesTourSourceSection(
            roundId: '$id-r',
            label: id,
            games: [for (var n = 0; n < 3; n++) _game('$id-$n', id)],
          ),
      ];
      expect(combinedVerticalGameIndex(sources, 0, 2, true), 2);
      expect(combinedVerticalGameIndex(sources, 1, 2, true), 2);
      expect(combinedVerticalGameIndex(sources, 2, 2, true), 3);
      expect(combinedVerticalGameIndex(sources, 3, 2, false), 2);
      expect(combinedVerticalGameIndex(sources, 4, 2, false), 2);
      expect(combinedVerticalGameIndex(sources, 5, 2, true), isNull);
    },
  );

  test('browser history restores the same Combined selection', () async {
    final c = _container();
    addTearDown(c.dispose);
    final id = c
        .read(desktopTabsProvider.notifier)
        .open(
          TabKind.tournamentDetail,
          title: 'Festival',
          reuseExisting: false,
        );
    c.read(tournamentByTabIdProvider.notifier).state = {
      id: GroupEventCardModel(
        id: 'event',
        title: 'Festival',
        dates: '',
        maxAvgElo: 2700,
        timeUntilStart: '',
        tourEventCategory: TourEventCategory.live,
        timeControl: 'rapid',
        startDate: _time,
        endDate: _time,
      ),
    };
    await c
        .read(combinedTournamentSelectionProvider.notifier)
        .select('event', true);
    final combined = captureDesktopWebPage(c);
    expect(
      Uri.parse(c.read(desktopWebLocationProvider)).queryParameters['combined'],
      '1',
    );
    await c
        .read(combinedTournamentSelectionProvider.notifier)
        .select('event', false);
    expect(
      Uri.parse(c.read(desktopWebLocationProvider)).queryParameters['combined'],
      isNull,
    );
    combined();
    expect(c.read(combinedTournamentSelectionProvider), contains('event'));
    expect(
      Uri.parse(c.read(desktopWebLocationProvider)).queryParameters['combined'],
      '1',
    );
  });

  test(
    'opening a Combined board preserves all sources, order and its browser URL',
    () {
      final games = [
        for (final id in ['a', 'b'])
          for (var n = 0; n < 40; n++) _game('$id-$n', id),
      ];
      final args = buildTournamentBoardTabArgs(
        games[35],
        'Festival',
        eventGames: games,
      );
      expect(args.eventGamesKey, isNull);
      expect(
        args.eventGames.map((game) => game.id),
        games.map((game) => game.gameId),
      );
      expect(args.sourceGame?.tourId, 'a');
      expect(eventGamesKeyForSummary(args.eventGames.last, args), isNull);
      expect(preserveTournamentEventInputOrder(args, args.eventGames), isTrue);
      expect(
        eventRailOrderedIdsForTesting(
          args.eventGames,
          preserveInputOrder: preserveTournamentEventInputOrder(
            args,
            args.eventGames,
          ),
        ),
        args.eventGames.map((game) => game.id),
      );
      final c = _container();
      addTearDown(c.dispose);
      final id = c.read(desktopTabsProvider.notifier).open(TabKind.board);
      c.read(boardTabGameArgsByTabIdProvider.notifier).state = {id: args};
      expect(
        Uri.parse(
          c.read(desktopWebLocationProvider),
        ).queryParameters['combined'],
        '1',
      );
    },
  );
  test(
    'combined game links rebuild real sources without organizer mirrors',
    () async {
      Tour tour(String id, String label, int rating) => Tour(
        id: id,
        name: 'Festival | $label',
        slug: id,
        info: const TourInfo(),
        createdAt: _time,
        url: '',
        tier: 0,
        dates: [_time],
        players: const [],
        avgElo: rating,
      );
      final tours = [
        tour('a', 'Group A', 2700),
        tour('mirror', 'Combined', 2900),
        tour('b', 'Group B', 2600),
      ];
      final rounds = _LinkRounds();
      final requested = <String>[];
      final c = ProviderContainer(
        overrides: [
          groupBroadcastRepositoryProvider.overrideWithValue(_LinkGroups()),
          tourRepositoryProvider.overrideWithValue(_LinkTours(tours)),
          roundRepositoryProvider.overrideWithValue(rounds),
          completeGamesTourFutureProvider.overrideWith((ref, id) async {
            requested.add(id);
            return [_row('$id-1', id), _row('foreign', 'outside')];
          }),
        ],
      );
      addTearDown(c.dispose);
      final restored = await c.read(combinedTournamentLinkProvider('a').future);
      expect(restored?.eventId, 'event');
      expect(restored?.games.map((game) => game.id), ['a-1', 'b-1']);
      expect(requested, unorderedEquals(['a', 'b']));
      expect(rounds.requested, ['a', 'b']);
      expect(restored?.games.map((game) => game.roundId), ['a-r', 'b-r']);
    },
  );

  testWidgets(
    'free Combined picker hides the organizer copy and opens every real group',
    (tester) async {
      Tour tour(String id, String label) => Tour(
        id: id,
        name: 'Festival | $label',
        slug: id,
        info: const TourInfo(),
        createdAt: _time,
        url: '',
        tier: 0,
        dates: [_time],
        players: const [],
      );
      final a = tour('a', 'Group A');
      final b = tour('b', 'Group B');
      final mirror = tour('mirror', 'Combined');
      final store = MemoryStore();
      final c = ProviderContainer(
        overrides: [
          selectedBroadcastModelProvider.overrideWith((ref) => _event),
          combinedTournamentStoreProvider.overrideWithValue(store),
          tourRepositoryProvider.overrideWithValue(_PendingTours()),
          liveTourIdProvider.overrideWith((ref) => Stream.value(const [])),
        ],
      );
      addTearDown(c.dispose);
      c
          .read(tourDetailScreenProvider.notifier)
          .setDataState(
            TourDetailViewModel(
              aboutTourModel: AboutTourModel.fromTour(a),
              liveTourIds: const [],
              tours: [
                for (final item in [a, b, mirror])
                  TourModel(tour: item, roundStatus: RoundStatus.ongoing),
              ],
            ),
          );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(body: TournamentCategorySwitcher()),
          ),
        ),
      );
      await tester.tap(find.text('Group A'));
      await tester.pumpAndSettle();
      expect(find.text('Combined · all 2'), findsOneWidget);
      expect(find.text('Combined'), findsNothing);
      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
      await tester.tap(find.text('Combined · all 2'));
      await tester.pumpAndSettle();
      expect(c.read(combinedTournamentSelectedProvider), isTrue);
      expect(store.values['event'], isTrue);
      expect(find.text('Combined'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _PendingTours implements TourRepository {
  final Completer<List<Tour>> _pending = Completer<List<Tour>>();
  @override
  Future<List<Tour>> getTourByGroupId(String groupId) => _pending.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LinkGroups implements GroupBroadcastRepository {
  @override
  Future<Map<String, String>> getTourToGroupBroadcastMapping(
    List<String> ids,
  ) async => {'a': 'event'};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LinkTours implements TourRepository {
  _LinkTours(this.tours);
  final List<Tour> tours;
  @override
  Future<List<Tour>> getTourByGroupId(String id) async => tours;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LinkRounds implements RoundRepository {
  List<String> requested = [];
  @override
  Future<Map<String, List<Round>>> getRoundsByTourIds(List<String> ids) async {
    requested = ids;
    return {
      for (final id in ids) id: [_round(id)],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
