import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';

const String tournamentLiveFirstPreferenceKey =
    'desktop_tournaments_live_first_v2';

abstract interface class TournamentLiveFirstStore {
  Future<bool?> read();

  Future<void> write(bool value);
}

class SqliteTournamentLiveFirstStore implements TournamentLiveFirstStore {
  SqliteTournamentLiveFirstStore({AppDatabase? database})
    : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  @override
  Future<bool?> read() => _database.getBool(tournamentLiveFirstPreferenceKey);

  @override
  Future<void> write(bool value) =>
      _database.setBool(tournamentLiveFirstPreferenceKey, value);
}

final tournamentLiveFirstStoreProvider = Provider<TournamentLiveFirstStore>(
  (ref) => SqliteTournamentLiveFirstStore(),
);

final tournamentLiveFirstProvider =
    StateNotifierProvider<TournamentLiveFirstController, bool>((ref) {
      return TournamentLiveFirstController(
        ref.watch(tournamentLiveFirstStoreProvider),
      );
    });

class TournamentLiveFirstController extends StateNotifier<bool> {
  TournamentLiveFirstController(this._store) : super(false) {
    restored = _restore();
  }

  final TournamentLiveFirstStore _store;
  late final Future<void> restored;
  bool _userChanged = false;

  Future<void> _restore() async {
    try {
      final saved = await _store.read();
      if (!mounted || _userChanged || saved == null) return;
      state = saved;
    } catch (error) {
      debugPrint('Tournament Live first preference restore failed: $error');
    }
  }

  Future<void> setEnabled(bool value) async {
    _userChanged = true;
    if (mounted) state = value;
    try {
      await _store.write(value);
    } catch (error) {
      debugPrint('Tournament Live first preference save failed: $error');
    }
  }

  Future<void> toggle() => setEnabled(!state);
}

bool shouldShowTournamentLiveFirst(GroupEventCategory category) =>
    category != GroupEventCategory.past;

/// Same activity window the Live smart collection uses when it actually
/// finds boards. The older two-hour badge window missed events the Live
/// filter still treats as live.
@visibleForTesting
const Duration liveFirstGameActivityWindow = Duration(hours: 8);

const _liveGameEventIdsRefreshInterval = Duration(minutes: 1);

/// Event IDs that currently have a live game.
///
/// Runs the unscoped sweep *always*: For You pages 20 events at a time ordered
/// by rating, so the live event Live first exists to surface is routinely one
/// the feed has not loaded yet. A query scoped to the rows already on screen
/// can never return it, which left the toggle a visual no-op. The visible-id
/// pass is kept as a second query on For You so a global slice of `games` can
/// still not miss an event the user is actually looking at; the two results are
/// unioned. Uses the Live collection's 8-hour window and `*` / `ongoing` /
/// `live` statuses.
final queriedLiveGameEventIdsProvider = AutoDisposeFutureProvider<Set<String>>((
  ref,
) async {
  final refresh = Timer(_liveGameEventIdsRefreshInterval, ref.invalidateSelf);
  ref.onDispose(refresh.cancel);

  final category = ref.watch(selectedGroupCategoryProvider);
  final visibleIds = <String>{
    for (final event in ref.watch(forYouEventsProvider).events)
      if (event.id.isNotEmpty) event.id,
  };
  final repository = ref.watch(gameRepositoryProvider);

  final ids = <String>{};
  Future<void> collect({List<String>? eventIds}) async {
    try {
      ids.addAll(
        await repository.getGroupBroadcastIdsWithLiveGames(
          eventIds: eventIds,
          staleAfterSeconds: liveFirstGameActivityWindow.inSeconds,
        ),
      );
    } catch (error) {
      debugPrint('Live-first games query failed: $error');
    }
  }

  await collect();
  if (category == GroupEventCategory.forYou && visibleIds.isNotEmpty) {
    await collect(eventIds: visibleIds.toList());
  }
  return ids;
});

/// Pre-loads live events the For You feed has not paged in yet.
///
/// `orderTournamentEventsForDisplay` can only promote events that are already
/// in the list. The feed pages 20 at a time ordered by rating, and a live event
/// frequently sits well below that window (a live club event can rank 25th),
/// so reordering alone has nothing to move and Live first reads as a dead
/// button.
///
/// This deliberately does **not** wait for the toggle to be switched on. Doing
/// the fetch on tap put two round trips (broadcast rows + top-game snapshots)
/// between the click and the resort, so the promotion visibly trailed the
/// button. Hydrating as soon as the live IDs are known makes the toggle a pure
/// in-memory reorder that lands on the same frame as the tap. Hydration itself
/// preserves source order so switching the preference off is reversible.
final tournamentLiveEventPrefetchProvider = Provider.autoDispose<void>((ref) {
  final liveIds = ref.watch(tournamentLiveGameEventIdsProvider);
  if (liveIds.isEmpty) return;

  final notifier = ref.read(forYouEventsProvider.notifier);
  // Off the build phase: this provider is read during a widget build and
  // `hydrateEvents` publishes new feed state. Pass every live id, not only
  // missing ones, so an already-loaded upcoming row that just went live is
  // recategorized without a restart. The display projection promotes it only
  // while Live first is enabled.
  Future.microtask(() => notifier.hydrateEvents(liveIds));
});

/// The same event IDs the For You "Live" status filter returns.
final forYouLiveFilterEventIdsProvider = AutoDisposeFutureProvider<Set<String>>((
  ref,
) async {
  final refresh = Timer(_liveGameEventIdsRefreshInterval, ref.invalidateSelf);
  ref.onDispose(refresh.cancel);

  try {
    final broadcasts = await ref
        .watch(groupBroadcastRepositoryProvider)
        .getForYouGroupBroadcasts(limit: 100, statusFilters: const ['live']);
    return {
      for (final broadcast in broadcasts)
        if (broadcast.id.isNotEmpty) broadcast.id,
    };
  } catch (error) {
    debugPrint('Live-first For You live filter query failed: $error');
    return const <String>{};
  }
});

/// Union of every signal the Live filter already trusts, plus live boards
/// already painted on For You cards.
final tournamentLiveGameEventIdsProvider = Provider.autoDispose<Set<String>>((
  ref,
) {
  return mergeTournamentLiveEventIds(
    configuredIds:
        ref.watch(configuredLiveGroupBroadcastIdsProvider).valueOrNull ??
        const <String>[],
    strictIds:
        ref.watch(liveGroupBroadcastIdsProvider).valueOrNull ??
        const <String>[],
    queriedIds:
        ref.watch(queriedLiveGameEventIdsProvider).valueOrNull ??
        const <String>{},
    liveFilterIds:
        ref.watch(forYouLiveFilterEventIdsProvider).valueOrNull ??
        const <String>{},
    snapshotIds: liveEventIdsFromForYouSnapshots(
      ref.watch(forYouTopGamesSnapshotCacheProvider),
    ),
  );
});

/// Combines Live-filter IDs, settings IDs, and live-game queries.
@visibleForTesting
Set<String> mergeTournamentLiveEventIds({
  Iterable<String> configuredIds = const [],
  Iterable<String> strictIds = const [],
  Iterable<String> queriedIds = const [],
  Iterable<String> liveFilterIds = const [],
  Iterable<String> snapshotIds = const [],
}) {
  return {
    for (final id in configuredIds)
      if (id.isNotEmpty) id,
    for (final id in strictIds)
      if (id.isNotEmpty) id,
    for (final id in queriedIds)
      if (id.isNotEmpty) id,
    for (final id in liveFilterIds)
      if (id.isNotEmpty) id,
    for (final id in snapshotIds)
      if (id.isNotEmpty) id,
  };
}

/// Whether a board row is an actual in-progress game with recent activity.
@visibleForTesting
bool isFreshLiveGame({
  required bool isOngoing,
  required DateTime? lastMoveTime,
  String? lastMove,
  DateTime? now,
  Duration staleAfter = liveIndicatorStaleAfter,
}) {
  if (!isOngoing) return false;
  if (lastMove != null && lastMove.trim().isEmpty) return false;
  if (lastMoveTime == null) return false;

  final effectiveNow = now ?? DateTime.now();
  if (lastMoveTime.isAfter(effectiveNow.add(const Duration(minutes: 2)))) {
    return false;
  }
  return !effectiveNow.isAfter(lastMoveTime.add(staleAfter));
}

@visibleForTesting
Set<String> liveEventIdsFromForYouSnapshots(
  Map<String, ForYouEventGamesSnapshot> snapshots, {
  DateTime? now,
}) {
  final ids = <String>{};
  snapshots.forEach((eventId, snapshot) {
    if (snapshot.visibleGames.any(
      (game) => isFreshLiveGame(
        isOngoing: game.gameStatus.isOngoing,
        lastMoveTime: game.lastMoveTime,
        lastMove: game.lastMove,
        now: now,
      ),
    )) {
      ids.add(eventId);
    }
  });
  return ids;
}

bool _eventHasLiveGames(
  GroupEventCardModel event, {
  required Set<String> liveGameEventIds,
}) {
  return liveGameEventIds.contains(event.id) ||
      event.tourEventCategory == TourEventCategory.live;
}

/// Returns a display-only ordering without mutating the provider-owned list.
///
/// When [liveFirst] is enabled, events with live games are promoted as one
/// stable cohort. The existing personalized order remains unchanged inside
/// both the live and non-live cohorts.
List<GroupEventCardModel> orderTournamentEventsForDisplay(
  Iterable<GroupEventCardModel> events, {
  required bool liveFirst,
  Set<String> liveGameEventIds = const <String>{},
}) {
  final ordered = events.toList(growable: false);
  if (!liveFirst) return ordered;

  return <GroupEventCardModel>[
    for (final event in ordered)
      if (_eventHasLiveGames(event, liveGameEventIds: liveGameEventIds)) event,
    for (final event in ordered)
      if (!_eventHasLiveGames(event, liveGameEventIds: liveGameEventIds)) event,
  ];
}
