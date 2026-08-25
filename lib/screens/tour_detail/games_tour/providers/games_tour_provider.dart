import 'dart:async';

import 'package:chessever/repository/local_storage/tournament/games/games_local_storage.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final shouldStreamProvider = StateProvider((ref) => true);
final liveGameCardsPauseReasonsProvider = StateProvider<Set<String>>(
  (ref) => const <String>{},
);
final liveGameCardsPausedProvider = Provider<bool>(
  (ref) => ref.watch(liveGameCardsPauseReasonsProvider).isNotEmpty,
);

const Duration kTournamentGamesRequestTimeout = Duration(seconds: 10);

@visibleForTesting
bool shouldRunTournamentSafetyRefresh({
  required bool globallyEnabled,
  required bool desktopManaged,
  required Iterable<bool> desktopConsumerActivity,
}) {
  return globallyEnabled &&
      (!desktopManaged || desktopConsumerActivity.any((active) => active));
}

@visibleForTesting
Future<List<Games>> loadInitialTournamentGames({
  required Future<List<Games>> Function() readCachedGames,
  required Future<List<Games>> Function() fetchFreshGames,
  bool useCache = true,
  Duration timeout = kTournamentGamesRequestTimeout,
  int suspectPageSize = 1000,
}) async {
  assert(suspectPageSize > 0);
  var cachedGames = const <Games>[];
  if (useCache) {
    cachedGames = await readCachedGames();
    final endsOnPageBoundary =
        cachedGames.isNotEmpty && cachedGames.length % suspectPageSize == 0;
    if (!endsOnPageBoundary && cachedGames.isNotEmpty) return cachedGames;
  }

  try {
    return await fetchFreshGames().timeout(timeout);
  } catch (_) {
    // A cache written before complete paging was introduced can contain exactly
    // one PostgREST page. Try to heal it, but retain offline availability when
    // that refresh cannot complete.
    if (cachedGames.isNotEmpty) return cachedGames;
    rethrow;
  }
}

void setLiveGameCardsPaused(
  WidgetRef ref, {
  required String reason,
  required bool paused,
}) {
  setLiveGameCardsPausedWithNotifier(
    ref.read(liveGameCardsPauseReasonsProvider.notifier),
    reason: reason,
    paused: paused,
  );
}

void setLiveGameCardsPausedWithNotifier(
  StateController<Set<String>> notifier, {
  required String reason,
  required bool paused,
}) {
  if (reason.isEmpty) return;

  final current = notifier.state;
  final hasReason = current.contains(reason);
  if (paused == hasReason) return;

  if (paused) {
    notifier.state = <String>{...current, reason};
  } else {
    notifier.state = <String>{...current}..remove(reason);
  }
}

final gamesTourProvider = AutoDisposeStateNotifierProvider.family<
  GamesTourNotifier,
  AsyncValue<List<Games>>,
  String
>((ref, tourId) => GamesTourNotifier(ref: ref, tourId: tourId));

/// Notifier that manages the list of games for a tournament.
///
/// **Architecture (Post-Revert):**
/// - This provider holds ALL games in memory as a list
/// - It does NOT maintain individual Supabase Realtime streams per game
/// - Instead, it uses periodic polling (every 5 seconds) to fetch updates
/// - Individual game cards use `liveGameCardProvider` with `.autoDispose`
///   to get realtime updates only for VISIBLE games
/// - When a game card scrolls out of view, its stream is disposed
///
/// This approach minimizes Supabase Realtime connections while still
/// providing instant updates for games the user is actively viewing.
class GamesTourNotifier extends StateNotifier<AsyncValue<List<Games>>> {
  GamesTourNotifier({required this.ref, required this.tourId})
    : super(const AsyncValue.loading()) {
    _loadInitialGames();

    // Listen to shouldStreamProvider changes
    _shouldStreamListener = ref.listen<bool>(shouldStreamProvider, (
      previous,
      next,
    ) {
      _reconcilePeriodicRefresh();
    });
  }

  final Ref ref;
  final String tourId;
  ProviderSubscription? _shouldStreamListener;
  Timer? _refreshTimer;
  bool _refreshLoopActive = false;
  bool _refreshInFlight = false;
  int _refreshGeneration = 0;
  final Map<String, bool> _desktopPollingConsumers = <String, bool>{};
  bool _desktopPollingManaged = false;

  bool get _periodicRefreshAllowed => shouldRunTournamentSafetyRefresh(
    globallyEnabled: ref.read(shouldStreamProvider),
    desktopManaged: _desktopPollingManaged,
    desktopConsumerActivity: _desktopPollingConsumers.values,
  );

  bool get backgroundRefreshAllowed => _periodicRefreshAllowed;

  /// Registers one retained desktop tournament pane without dropping its last
  /// data when hidden. Mobile callers never register and preserve the existing
  /// polling behavior. Multiple tabs sharing a tour poll while any is active.
  void setDesktopPollingConsumer({
    required String consumerId,
    required bool active,
  }) {
    if (consumerId.isEmpty || _desktopPollingConsumers[consumerId] == active) {
      return;
    }
    _desktopPollingManaged = true;
    _desktopPollingConsumers[consumerId] = active;
    _reconcilePeriodicRefresh();
  }

  void removeDesktopPollingConsumer(String consumerId) {
    if (_desktopPollingConsumers.remove(consumerId) == null) return;
    _reconcilePeriodicRefresh();
  }

  void _reconcilePeriodicRefresh() {
    if (_periodicRefreshAllowed && state.hasValue) {
      if (!_refreshLoopActive) _startPeriodicRefresh();
    } else {
      _stopPeriodicRefresh();
    }
  }

  Future<void> _loadInitialGames({bool forceRefresh = false}) async {
    try {
      final gamesLocalStorageProvider = ref.read(gamesLocalStorage);
      var loadedFromCache = false;
      final games = await loadInitialTournamentGames(
        readCachedGames: () async {
          final cachedGames = await gamesLocalStorageProvider.getCachedGames(
            tourId,
          );
          loadedFromCache = cachedGames.isNotEmpty;
          return cachedGames;
        },
        fetchFreshGames: () {
          loadedFromCache = false;
          return gamesLocalStorageProvider.fetchAndSaveGames(
            tourId,
            forceRefresh: forceRefresh,
          );
        },
        useCache: !forceRefresh,
      );

      if (mounted) {
        state = AsyncValue.data(games);

        // Cached rows keep the first paint fast, but a non-empty cache is not
        // proof that a live tournament snapshot is complete. Refresh this same
        // mounted primary notifier immediately so an arbitrary partial cache
        // cannot remain visible indefinitely when desktop polling registration
        // is delayed or briefly inactive. Sibling stages retain their staggered
        // safety refresh to avoid a burst of simultaneous requests.
        if (loadedFromCache && _isPrimaryTour) {
          unawaited(_checkForNewGames(ignoreActivity: true));
        }

        // Only start periodic refresh if streaming is enabled
        if (_periodicRefreshAllowed) {
          _startPeriodicRefresh();
        }
      }
    } catch (error, stackTrace) {
      if (mounted) {
        debugPrint(
          'GamesTourNotifier: initial load failed for $tourId: $error',
        );
        state = AsyncValue.error(error, stackTrace);
      }
    }
  }

  // Per-MOVE updates for visible games come from batched Supabase Realtime
  // channels (see liveGameCardProvider / LiveGamesBatchKey), NOT this poll.
  // This timer is only a slow safety net for set-level changes the per-game
  // streams don't cover: newly added games, round rollovers, completions that
  // arrive while a card is off-screen. Keep the selected tour responsive, but
  // avoid starting a synchronized network loop for every sibling stage in
  // multi-stage events.
  static const Duration _primarySafetyNetInterval = Duration(seconds: 5);
  static const Duration _siblingSafetyNetInterval = Duration(seconds: 45);
  static const Duration _primaryFirstSafetyNetDelay = Duration(seconds: 2);
  static const Duration _siblingFirstSafetyNetDelayBase = Duration(seconds: 24);

  bool get _isPrimaryTour {
    final primaryTourId =
        ref.read(tourDetailScreenProvider).valueOrNull?.aboutTourModel.id;
    return primaryTourId == null ||
        primaryTourId.isEmpty ||
        primaryTourId == tourId;
  }

  int get _stableTourJitterSeconds {
    var hash = 0;
    for (final codeUnit in tourId.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    return hash % 12;
  }

  Duration get _safetyNetInterval =>
      _isPrimaryTour ? _primarySafetyNetInterval : _siblingSafetyNetInterval;

  Duration get _firstSafetyNetDelay =>
      _isPrimaryTour
          ? _primaryFirstSafetyNetDelay
          : _siblingFirstSafetyNetDelayBase +
              Duration(seconds: _stableTourJitterSeconds);

  void _startPeriodicRefresh() {
    if (!_periodicRefreshAllowed || !mounted) return;
    _stopPeriodicRefresh();

    final interval = _safetyNetInterval;
    final firstDelay = _firstSafetyNetDelay;
    final generation = _refreshGeneration;
    _refreshLoopActive = true;

    _refreshTimer = Timer(firstDelay, () async {
      await _checkForNewGames();
      if (!mounted || !_refreshLoopActive || generation != _refreshGeneration) {
        return;
      }

      _refreshTimer = Timer.periodic(interval, (_) async {
        if (!_refreshLoopActive || generation != _refreshGeneration) return;
        await _checkForNewGames();
      });
    });

    debugPrint(
      '🔥 GamesTourNotifier: Started safety-net refresh '
      '(${interval.inSeconds}s interval, first in ${firstDelay.inSeconds}s) '
      'for tour $tourId',
    );
  }

  void _stopPeriodicRefresh() {
    _refreshGeneration++;
    _refreshLoopActive = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    debugPrint(
      '🔥 GamesTourNotifier: Stopped periodic refresh for tour $tourId',
    );
  }

  Future<void> _checkForNewGames({bool ignoreActivity = false}) async {
    if (!mounted ||
        (!ignoreActivity && !_periodicRefreshAllowed) ||
        _refreshInFlight) {
      return;
    }
    _refreshInFlight = true;
    try {
      final currentGames = state.valueOrNull;
      if (currentGames == null) return;

      // Fetch fresh games from the server
      final gamesLocalStorageProvider = ref.read(gamesLocalStorage);
      final freshGames = await gamesLocalStorageProvider.fetchAndSaveGames(
        tourId,
        forceRefresh: true,
      );
      if (!mounted) return;

      final currentById = {for (final game in currentGames) game.id: game};
      final freshIds = <String>{};
      bool hasChanges = freshGames.length != currentGames.length;
      final mergedGames = <Games>[];

      if (freshGames.length != currentGames.length) {
        debugPrint(
          '🔥 GamesTourNotifier: Detected game count change! Current: ${currentGames.length}, Fresh: ${freshGames.length}',
        );
      }

      for (final fresh in freshGames) {
        freshIds.add(fresh.id);
        final current = currentById[fresh.id];

        if (current == null) {
          // New game added
          hasChanges = true;
          mergedGames.add(fresh);
          continue;
        }

        if (_hasSafetyNetChange(current, fresh)) {
          hasChanges = true;
        }

        mergedGames.add(_mergeSafetyNetSnapshot(current, fresh));
      }

      // Check for removed games
      for (final removedId in currentById.keys) {
        if (!freshIds.contains(removedId)) {
          hasChanges = true;
        }
      }

      if (hasChanges && mounted) {
        state = AsyncValue.data(mergedGames);
      }
    } catch (error) {
      if (!mounted) return;
      debugPrint('🔥 GamesTourNotifier: Error checking for new games: $error');
    } finally {
      _refreshInFlight = false;
    }
  }

  bool _hasSafetyNetChange(Games current, Games fresh) {
    return (fresh.status != null && current.status != fresh.status) ||
        current.roundId != fresh.roundId ||
        current.roundSlug != fresh.roundSlug ||
        current.name != fresh.name ||
        !listEquals(current.search, fresh.search) ||
        current.boardNr != fresh.boardNr ||
        current.dateStart != fresh.dateStart;
  }

  Games _mergeSafetyNetSnapshot(Games current, Games fresh) {
    return current.copyWith(
      roundId: fresh.roundId,
      roundSlug: fresh.roundSlug,
      name: fresh.name,
      search: fresh.search,
      boardNr: fresh.boardNr,
      dateStart: fresh.dateStart,
      status: fresh.status ?? current.status,
    );
  }

  Future<void> refreshGames({bool forceRefresh = false}) async {
    if (forceRefresh && state.valueOrNull != null) {
      await _checkForNewGames(ignoreActivity: true);
      return;
    }
    await _loadInitialGames(forceRefresh: forceRefresh);
  }

  Future<void> retry() async {
    if (!mounted) return;
    state = const AsyncValue.loading();
    await _loadInitialGames(forceRefresh: true);
  }

  @override
  void dispose() {
    _stopPeriodicRefresh();
    _shouldStreamListener?.close();
    super.dispose();
  }
}
