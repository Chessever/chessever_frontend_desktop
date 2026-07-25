import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';

final _searchFocusGroupedStateProvider = StateProvider<GroupedGamesData>(
  (ref) => throw UnimplementedError(),
);

void main() {
  test('hidden retained tournament panes suspend only their safety poll', () {
    expect(
      shouldRunTournamentSafetyRefresh(
        globallyEnabled: true,
        desktopManaged: false,
        desktopConsumerActivity: const <bool>[],
      ),
      isTrue,
      reason: 'Mobile/unmanaged consumers retain their existing behavior.',
    );
    expect(
      shouldRunTournamentSafetyRefresh(
        globallyEnabled: true,
        desktopManaged: true,
        desktopConsumerActivity: const <bool>[false, false],
      ),
      isFalse,
    );
    expect(
      shouldRunTournamentSafetyRefresh(
        globallyEnabled: true,
        desktopManaged: true,
        desktopConsumerActivity: const <bool>[false, true],
      ),
      isTrue,
    );
  });

  testWidgets(
    '1,000-game tournament mounts and streams only the viewport window',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _TrackingGameStreamRepository();
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final games = List<GamesTourModel>.generate(
        1000,
        (index) => _game(index),
        growable: false,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(
              _EvaluationBarOffNotifier.new,
            ),
            engineSettingsProviderNew.overrideWith(
              _EngineSettingsOffNotifier.new,
            ),
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                ResponsiveHelper.init(context);
                return Scaffold(
                  body: buildLazyTournamentGamesViewportForTesting(
                    games: games,
                    scrollController: scrollController,
                    layout: DesktopCardLayout.compact,
                    cacheExtent: 400,
                    scopeId: 'thousand-games',
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final initiallyMounted =
          find.byType(LiveDesktopGameCard).evaluate().length;
      expect(initiallyMounted, inInclusiveRange(1, 100));
      expect(
        find.byKey(
          const ValueKey<String>(
            'tournament-lazy-card:thousand-games:game-999',
          ),
        ),
        findsNothing,
      );
      expect(repository.individualSubscriptions, 0);
      expect(repository.roundSubscriptions, 0);
      expect(repository.tourSubscriptions, 0);
      expect(repository.activeBatchSubscriptions, inInclusiveRange(1, 4));
      expect(
        repository.requestedBatchSizes,
        everyElement(inInclusiveRange(1, 25)),
      );

      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey<String>(
            'tournament-lazy-card:thousand-games:game-999',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byType(LiveDesktopGameCard).evaluate().length,
        inInclusiveRange(1, 100),
      );
      expect(repository.activeBatchSubscriptions, inInclusiveRange(1, 4));
      expect(repository.peakActiveBatchSubscriptions, lessThanOrEqualTo(8));
      expect(repository.batchSubscriptions, lessThanOrEqualTo(8));

      // Removing the viewport must release every Realtime leaf. Retained game
      // rows remain in the parent model; only offscreen subscriptions go away.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump();
      expect(repository.activeBatchSubscriptions, 0);
    },
  );

  testWidgets('tournament grid cards reserve opening for double click', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _TrackingGameStreamRepository();
    final scrollController = ScrollController();
    final selectedGameIds = <String>[];
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _EngineSettingsOffNotifier.new,
          ),
          gameStreamRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return Scaffold(
                body: buildLazyTournamentGamesViewportForTesting(
                  games: <GamesTourModel>[_game(0)],
                  scrollController: scrollController,
                  onSelectGame: selectedGameIds.add,
                  layout: DesktopCardLayout.grid,
                  scopeId: 'board-click-contract',
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final card = tester.widget<DesktopGameCard>(find.byType(DesktopGameCard));
    expect(card.onTap, isNull);
    expect(
      card.onDoubleTap,
      isNotNull,
      reason:
          'The keyboard item owns single-click selection, so the card must '
          'reserve game opening for double click.',
    );
    expect(card.dragPayload, isNotNull);

    await tester.tap(find.byType(DesktopGameCard));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selectedGameIds, <String>['game-0']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump();
    expect(repository.activeBatchSubscriptions, 0);
  });

  testWidgets(
    'search focus survives populated-to-empty results and Backspace edits text',
    (tester) async {
      final game = GamesTourModel(
        gameId: 'search-focus-game',
        whitePlayer: _player('White'),
        blackPlayer: _player('Black'),
        whiteTimeDisplay: '05:00',
        blackTimeDisplay: '05:00',
        whiteClockCentiseconds: 30000,
        blackClockCentiseconds: 30000,
        gameStatus: GameStatus.ongoing,
        roundId: 'search-focus-round',
        tourId: '',
      );
      final round = GamesAppBarModel(
        id: game.roundId,
        name: 'Round 1',
        startsAt: DateTime.utc(2026, 7, 24, 12),
        roundStatus: RoundStatus.ongoing,
      );
      final populated = GroupedGamesData(
        filteredRounds: [round],
        gamesByRound: {
          round.id: [game],
        },
        isKnockoutTournament: false,
        isMultiStageKnockout: false,
        isLoading: false,
        rounds: [round],
        allGames: [game],
        providerGameCount: 1,
      );
      final empty = GroupedGamesData(
        filteredRounds: const [],
        gamesByRound: const {},
        isKnockoutTournament: false,
        isMultiStageKnockout: false,
        isLoading: false,
        rounds: const [],
        allGames: const [],
        providerGameCount: 1,
      );
      final container = ProviderContainer(
        overrides: [
          _searchFocusGroupedStateProvider.overrideWith((ref) => populated),
          gamesTourGroupedProvider.overrideWith(
            (ref) => ref.watch(_searchFocusGroupedStateProvider),
          ),
          gamesTourScreenProvider.overrideWith(
            (ref) => _SearchFocusGamesNotifier(ref),
          ),
          boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _EngineSettingsOffNotifier.new,
          ),
          gameStreamRepositoryProvider.overrideWithValue(
            _TrackingGameStreamRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      var backNavigationCount = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Focus(
                autofocus: true,
                onKeyEvent:
                    (node, event) => handleDesktopShellBackspaceKeyEvent(
                      event: event,
                      canGoBack: true,
                      primaryFocus: FocusManager.instance.primaryFocus,
                      onBack: () => backNavigationCount += 1,
                    ),
                child: const TournamentGamesView(
                  tabId: 'search-focus-tab',
                  tournamentId: 'search-focus-tour',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final search = find.byType(TextField);
      expect(search, findsOneWidget);
      await tester.tap(search);
      await tester.enterText(search, 'definitely no matching game');
      await tester.pump(const Duration(milliseconds: 350));
      container.read(_searchFocusGroupedStateProvider.notifier).state = empty;
      await tester.pump();

      expect(
        find.text('No games match "definitely no matching game"'),
        findsOneWidget,
      );
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(
        tester.widget<TextField>(search).controller?.text,
        'definitely no matching gam',
      );
      expect(backNavigationCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

class _SearchFocusGamesNotifier extends GamesTourScreenProvider {
  _SearchFocusGamesNotifier(Ref ref) : super.loading(ref: ref) {
    state = AsyncData(_state());
  }

  static GamesScreenModel _state({String? query}) {
    return GamesScreenModel(
      gamesTourModels: const [],
      pinnedGamedIs: const [],
      isSearchMode: query != null,
      searchQuery: query,
    );
  }

  @override
  Future<void> searchGamesEnhanced(String query) async {
    state = AsyncData(_state(query: query));
  }

  @override
  void clearSearch() {
    state = AsyncData(_state());
  }
}

class _TrackingGameStreamRepository extends GameStreamRepository {
  int individualSubscriptions = 0;
  int batchSubscriptions = 0;
  int roundSubscriptions = 0;
  int tourSubscriptions = 0;
  int activeBatchSubscriptions = 0;
  int peakActiveBatchSubscriptions = 0;
  final List<int> requestedBatchSizes = <int>[];

  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) {
    individualSubscriptions++;
    return const Stream<LiveGameUpdate?>.empty();
  }

  @override
  Stream<Map<String, dynamic>?> subscribeToGameUpdates(String gameId) {
    individualSubscriptions++;
    return const Stream<Map<String, dynamic>?>.empty();
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) {
    batchSubscriptions++;
    requestedBatchSizes.add(gameIds.length);
    late final StreamController<Map<String, LiveGameUpdate>> controller;
    controller = StreamController<Map<String, LiveGameUpdate>>(
      onListen: () {
        activeBatchSubscriptions++;
        if (activeBatchSubscriptions > peakActiveBatchSubscriptions) {
          peakActiveBatchSubscriptions = activeBatchSubscriptions;
        }
      },
      onCancel: () {
        activeBatchSubscriptions--;
        scheduleMicrotask(controller.close);
      },
    );
    return controller.stream;
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) {
    roundSubscriptions++;
    return const Stream<Map<String, LiveGameUpdate>>.empty();
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) {
    tourSubscriptions++;
    return const Stream<Map<String, LiveGameUpdate>>.empty();
  }
}

GamesTourModel _game(int index) {
  return GamesTourModel(
    gameId: 'game-$index',
    whitePlayer: _player('White $index'),
    blackPlayer: _player('Black $index'),
    whiteTimeDisplay: '05:00',
    blackTimeDisplay: '05:00',
    whiteClockCentiseconds: 30000,
    blackClockCentiseconds: 30000,
    gameStatus: GameStatus.ongoing,
    roundId: 'round-1',
    tourId: 'tour-1',
    tourSlug: 'stress-event',
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: null,
  );
}

class _EvaluationBarOffNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _EngineSettingsOffNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings(showEngineGauge: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}
