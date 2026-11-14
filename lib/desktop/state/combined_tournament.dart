import 'package:chessever/desktop/combined/combined_hall_provider.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/combined/combined_category.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/desktop/combined/combined_round_buckets.dart';
import 'package:chessever/desktop/combined/combined_round_sections.dart';
import 'package:chessever/desktop/panes/tournament_detail_pane.dart'
    show tournamentDetailGamesSearchByTabIdProvider;
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/round/round_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/live_rounds_id_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';

export 'package:chessever/desktop/combined/combined_category.dart';
export 'package:chessever/desktop/combined/combined_round_buckets.dart';

const combinedTournamentCategoryId = '__chessever_combined__';

abstract interface class CombinedTournamentStore {
  Future<bool?> read(String eventId);
  Future<void> write(String eventId, bool selected);
}

class SqliteCombinedTournamentStore implements CombinedTournamentStore {
  @override
  Future<bool?> read(String eventId) =>
      AppDatabase.instance.getBool('combined_category_$eventId');
  @override
  Future<void> write(String eventId, bool selected) =>
      AppDatabase.instance.setBool('combined_category_$eventId', selected);
}

final combinedTournamentStoreProvider = Provider<CombinedTournamentStore>(
  (ref) => SqliteCombinedTournamentStore(),
);
final combinedTournamentSelectionProvider =
    StateNotifierProvider<CombinedTournamentSelection, Set<String>>(
      (ref) => CombinedTournamentSelection(
        ref.watch(combinedTournamentStoreProvider),
      ),
    );

/// Same preference for native and browser builds; late storage reads cannot
/// overwrite a choice made while the event was opening.
class CombinedTournamentSelection extends StateNotifier<Set<String>> {
  CombinedTournamentSelection(this.store) : super(const {});
  final CombinedTournamentStore store;
  final Map<String, Future<void>> _loads = {};
  final Set<String> _touched = {};

  Future<void> ensureLoaded(String eventId) =>
      _loads.putIfAbsent(eventId, () async {
        try {
          final selected = await store.read(eventId);
          if (mounted && !_touched.contains(eventId) && selected == true) {
            state = {...state, eventId};
          }
        } catch (_) {
          /* Keep session preferences when storage is unavailable. */
        }
      });

  Future<void> select(String eventId, bool selected) async {
    _touched.add(eventId);
    state = selected ? {...state, eventId} : ({...state}..remove(eventId));
    try {
      await store.write(eventId, selected);
    } catch (_) {
      /* Selection still works for this session. */
    }
  }
}

final combinedTournamentCategoriesProvider = Provider<CombinedCategories>((
  ref,
) {
  final event = ref.watch(selectedBroadcastModelProvider);
  final tours = ref.watch(tourDetailScreenProvider).valueOrNull?.tours;
  if (event == null || tours == null) return CombinedCategories.none;
  return CombinedCategories.fromTours(tours, groupName: event.name);
});

final combinedTournamentSelectedProvider = Provider<bool>((ref) {
  final id = ref.watch(selectedBroadcastModelProvider)?.id;
  return id != null &&
      ref.watch(combinedTournamentCategoriesProvider).canCombine &&
      ref.watch(combinedTournamentSelectionProvider).contains(id);
});

final combinedTournamentDisplayModeProvider = StateProvider<GameDisplayMode>(
  (ref) => GameDisplayMode.all,
);

class CombinedTournamentData {
  CombinedTournamentData({
    required this.grouped,
    this.buckets = const [],
    this.sections = const [],
  });
  final GroupedGamesData grouped;
  final List<CombinedRoundBucket> buckets;
  final List<CombinedRoundSection> sections;
  List<GamesTourSourceSection> sourcesFor(String roundId) =>
      buckets
          .where((bucket) => bucket.round.id == roundId)
          .firstOrNull
          ?.sources ??
      const [];
}

/// Shared by desktop and app.chessever.com. Filtering never changes the source
/// schedules used to order stages, and real game/tour/round ids stay intact.
final combinedTournamentCatalogProvider =
    Provider.autoDispose<CombinedTournamentData>((ref) {
      final categories = ref.watch(combinedTournamentCategoriesProvider);
      final eventId = ref.watch(selectedBroadcastModelProvider)?.id ?? '';
      final key = categories.tourIds.join(',');
      ref.watch(combinedHallProvider(key));
      final hall = ref.read(combinedHallProvider(key).notifier);
      final raw = hall.gamesByTour;
      final loading = hall.loader.isLoading;
      final error =
          hall.loader.catalogs.isEmpty && hall.loader.failures.isNotEmpty
              ? StateError(
                'Combined rounds could not be loaded. Retry to continue.',
              )
              : null;
      // Nothing until every category's schedule is in: a schedule that
      // arrives later would regroup every round card in front of the viewer.
      final sections = buildCombinedRoundSections(
        categories: categories.items,
        gamesByTourId: loading ? const {} : raw,
        roundsByTourId: loading ? const {} : hall.loader.catalogs,
        includeEmptyRounds: true,
        liveRoundIds: ref.watch(liveRoundsIdProvider).valueOrNull ?? const [],
      );
      final buckets = buildCombinedRoundBuckets(
        sections,
        eventId: eventId,
        loadedRoundIds: hall.loader.loaded,
        failedRoundIds: {
          for (final key in hall.loader.failures)
            if (key.startsWith('round:')) key.substring(6),
        },
      );
      final allGames = [for (final section in sections) ...section.games];
      return CombinedTournamentData(
        buckets: buckets,
        sections: sections,
        grouped: GroupedGamesData(
          filteredRounds: [for (final bucket in buckets) bucket.round],
          rounds: [for (final bucket in buckets) bucket.round],
          gamesByRound: {
            for (final bucket in buckets) bucket.round.id: bucket.games,
          },
          allGames: allGames,
          providerGameCount: allGames.length,
          isKnockoutTournament: false,
          isMultiStageKnockout: false,
          isLoading: loading,
          loadError: raw.isEmpty ? error : null,
        ),
      );
    });

final combinedTournamentDataProvider = Provider.autoDispose.family<
  CombinedTournamentData,
  String
>((ref, tabId) {
  final catalog = ref.watch(combinedTournamentCatalogProvider);
  final query =
      ref
          .watch(tournamentDetailGamesSearchByTabIdProvider(tabId))
          .trim()
          .toLowerCase();
  final words =
      query.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  final mode = ref.watch(combinedTournamentDisplayModeProvider);
  bool visible(GamesTourModel game) {
    if (!isGameStatusVisible(displayMode: mode, gameStatus: game.gameStatus)) {
      return false;
    }
    final white = game.whitePlayer, black = game.blackPlayer;
    final haystack =
        '${white.name} ${white.title} ${white.federation} ${white.countryCode} ${black.name} ${black.title} ${black.federation} ${black.countryCode} ${game.eco ?? ''} ${game.openingName ?? ''}'
            .toLowerCase();
    return words.every(haystack.contains);
  }

  if (words.isEmpty && mode == GameDisplayMode.all) return catalog;
  final allBuckets = catalog.buckets;
  final buckets =
      [
        for (final bucket in allBuckets)
          CombinedRoundBucket(
            round: bucket.round,
            sources:
                [
                  for (final source in bucket.sources)
                    GamesTourSourceSection(
                      roundId: source.roundId,
                      label: source.label,
                      games: source.games.where(visible).toList(),
                    ),
                ].where((source) => source.games.isNotEmpty).toList(),
          ),
      ].where((bucket) => bucket.sources.isNotEmpty).toList();
  final allGames = catalog.grouped.allGames;
  return CombinedTournamentData(
    buckets: buckets,
    sections: catalog.sections,
    grouped: GroupedGamesData(
      filteredRounds: [for (final bucket in buckets) bucket.round],
      rounds: catalog.grouped.rounds,
      gamesByRound: {
        for (final bucket in buckets) bucket.round.id: bucket.games,
      },
      allGames: allGames,
      providerGameCount: allGames.length,
      isKnockoutTournament: false,
      isMultiStageKnockout: false,
      isLoading: catalog.grouped.isLoading,
      loadError: catalog.grouped.loadError,
    ),
  );
});

class CombinedTournamentLinkData {
  const CombinedTournamentLinkData({
    required this.eventId,
    required this.games,
  });
  final String eventId;
  final List<TournamentGameSummary> games;
}

/// Rebuilds the same event rail after reloading a combined=1 game address.
/// Read-only source data, four concurrent source loads at most; every board
/// retains the source ids used by streams, admission and game hydration.
final combinedTournamentLinkProvider = FutureProvider.autoDispose
    .family<CombinedTournamentLinkData?, String>((ref, tourId) async {
      final lifetime = ref.keepAlive();
      try {
        final mapping = await ref
            .read(groupBroadcastRepositoryProvider)
            .getTourToGroupBroadcastMapping([tourId]);
        final eventId = mapping[tourId];
        if (eventId == null || eventId.isEmpty) return null;
        final tours = await ref
            .read(tourRepositoryProvider)
            .getTourByGroupId(eventId);
        final categories = CombinedCategories.fromTours([
          for (final tour in tours)
            TourModel(tour: tour, roundStatus: RoundStatus.ongoing),
        ]);
        if (!categories.canCombine || !categories.tourIds.contains(tourId)) {
          return null;
        }
        final rounds = await ref
            .read(roundRepositoryProvider)
            .getRoundsByTourIds(categories.tourIds);
        final games = <String, List<GamesTourModel>>{};
        for (var start = 0; start < categories.tourIds.length; start += 4) {
          final ids = categories.tourIds.skip(start).take(4).toList();
          final loaded = await Future.wait([
            for (final id in ids)
              ref.watch(completeGamesTourFutureProvider(id).future),
          ]);
          for (var i = 0; i < ids.length; i++) {
            games[ids[i]] = [
              for (final game in loaded[i])
                if (game.tourId == ids[i] &&
                    (game.players?.length ?? 0) >= 2 &&
                    game.players!
                        .take(2)
                        .every((player) => player.name.isNotEmpty))
                  GamesTourModel.fromGame(game),
            ];
          }
        }
        final sections = buildCombinedRoundSections(
          categories: categories.items,
          gamesByTourId: games,
          roundsByTourId: rounds,
          liveRoundIds: const [],
        );
        return CombinedTournamentLinkData(
          eventId: eventId,
          games: [
            for (final section in sections)
              for (final game in section.games)
                TournamentGameSummary.fromGamesTourModel(
                  game,
                  roundStartsAt: section.startsAt,
                  roundName: section.round.name,
                ),
          ],
        );
      } finally {
        lifetime.close();
      }
    });
