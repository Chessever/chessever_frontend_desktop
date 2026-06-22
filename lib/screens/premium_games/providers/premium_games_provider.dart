import 'dart:async';

import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// ============================================================================
// ENUMS & MODELS
// ============================================================================

/// Type of premium games collection to display.
enum PremiumGamesType {
  /// Games featuring the user's favorite players.
  favorites,

  /// Games featuring players from the user's country.
  countrymen,

  /// All games that are currently live.
  live,

  /// Games where the average rating of both players is at least 2500.
  gm,

  /// Games from classical/standard time-control broadcasts.
  classical,
}

/// Date range filter for premium games.
enum PremiumGamesDateRange { last7Days, last30Days, last90Days, allTime }

extension PremiumGamesDateRangeExtension on PremiumGamesDateRange {
  String get displayText {
    switch (this) {
      case PremiumGamesDateRange.last7Days:
        return 'Last 7 days';
      case PremiumGamesDateRange.last30Days:
        return 'Last 30 days';
      case PremiumGamesDateRange.last90Days:
        return 'Last 90 days';
      case PremiumGamesDateRange.allTime:
        return 'All time';
    }
  }

  DateTime? get startDate {
    final now = DateTime.now();
    switch (this) {
      case PremiumGamesDateRange.last7Days:
        return now.subtract(const Duration(days: 7));
      case PremiumGamesDateRange.last30Days:
        return now.subtract(const Duration(days: 30));
      case PremiumGamesDateRange.last90Days:
        return now.subtract(const Duration(days: 90));
      case PremiumGamesDateRange.allTime:
        return null;
    }
  }
}

/// Result filter for premium games.
enum PremiumGamesResult { all, whiteWins, blackWins, draw }

extension PremiumGamesResultExtension on PremiumGamesResult {
  String get displayText {
    switch (this) {
      case PremiumGamesResult.all:
        return 'All';
      case PremiumGamesResult.whiteWins:
        return 'White wins';
      case PremiumGamesResult.blackWins:
        return 'Black wins';
      case PremiumGamesResult.draw:
        return 'Draws';
    }
  }

  bool matches(GameStatus status) {
    switch (this) {
      case PremiumGamesResult.all:
        return true;
      case PremiumGamesResult.whiteWins:
        return status == GameStatus.whiteWins;
      case PremiumGamesResult.blackWins:
        return status == GameStatus.blackWins;
      case PremiumGamesResult.draw:
        return status == GameStatus.draw;
    }
  }
}

/// Filter settings for premium games.
class PremiumGamesFilter {
  const PremiumGamesFilter({
    this.dateRange = PremiumGamesDateRange.allTime,
    this.result = PremiumGamesResult.all,
    this.minElo,
    this.maxElo,
  });

  final PremiumGamesDateRange dateRange;
  final PremiumGamesResult result;
  final int? minElo;
  final int? maxElo;

  bool get hasActiveFilters {
    return dateRange != PremiumGamesDateRange.allTime ||
        result != PremiumGamesResult.all ||
        minElo != null ||
        maxElo != null;
  }

  PremiumGamesFilter copyWith({
    PremiumGamesDateRange? dateRange,
    PremiumGamesResult? result,
    int? minElo,
    int? maxElo,
    bool clearElo = false,
  }) {
    return PremiumGamesFilter(
      dateRange: dateRange ?? this.dateRange,
      result: result ?? this.result,
      minElo: clearElo ? null : (minElo ?? this.minElo),
      maxElo: clearElo ? null : (maxElo ?? this.maxElo),
    );
  }

  static const PremiumGamesFilter defaultFilter = PremiumGamesFilter();
}

/// State for premium games screen.
class PremiumGamesState {
  const PremiumGamesState({
    required this.games,
    required this.filter,
    required this.isLoadingMore,
    required this.hasMore,
  });

  final List<GamesTourModel> games;
  final PremiumGamesFilter filter;
  final bool isLoadingMore;
  final bool hasMore;

  static const initial = PremiumGamesState(
    games: [],
    filter: PremiumGamesFilter.defaultFilter,
    isLoadingMore: false,
    hasMore: true,
  );

  PremiumGamesState copyWith({
    List<GamesTourModel>? games,
    PremiumGamesFilter? filter,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return PremiumGamesState(
      games: games ?? this.games,
      filter: filter ?? this.filter,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

class _PremiumGamesFetch {
  const _PremiumGamesFetch({
    required this.games,
    required this.hasMore,
    required this.nextOffset,
  });

  final List<GamesTourModel> games;
  final bool hasMore;
  final int nextOffset;
}

// ============================================================================
// PROVIDER
// ============================================================================

/// Provider for premium games filter state (persists across rebuilds).
final premiumGamesFilterProvider =
    StateProvider.family<PremiumGamesFilter, PremiumGamesType>(
      (ref, type) => PremiumGamesFilter.defaultFilter,
    );

/// Provider for premium games based on type.
final premiumGamesProvider = StateNotifierProvider.autoDispose.family<
  PremiumGamesNotifier,
  AsyncValue<PremiumGamesState>,
  PremiumGamesType
>((ref, type) {
  ref.keepAlive();
  return PremiumGamesNotifier(ref, type);
});

/// Notifier for managing premium games state.
class PremiumGamesNotifier
    extends StateNotifier<AsyncValue<PremiumGamesState>> {
  PremiumGamesNotifier(this._ref, this._type)
    : super(const AsyncValue.loading()) {
    _initialize();
  }

  final Ref _ref;
  final PremiumGamesType _type;

  final List<GamesTourModel> _allGames = [];
  bool _hasMore = true;
  bool _isFetching = false;
  int _offset = 0;
  static const int _pageSize = 30;
  static const Duration _smartEventRefreshInterval = Duration(minutes: 1);
  Timer? _smartEventRefreshTimer;

  Future<void> _initialize() async {
    await loadGames();
    _startSmartEventRefreshTimer();
  }

  bool get _isCurrentSmartEventType {
    return _type == PremiumGamesType.live ||
        _type == PremiumGamesType.gm ||
        _type == PremiumGamesType.classical;
  }

  void _startSmartEventRefreshTimer() {
    if (!_isCurrentSmartEventType || _smartEventRefreshTimer != null) return;
    _smartEventRefreshTimer = Timer.periodic(_smartEventRefreshInterval, (_) {
      unawaited(loadGames(showLoading: false));
    });
  }

  @override
  void dispose() {
    _smartEventRefreshTimer?.cancel();
    super.dispose();
  }

  /// Load initial games with current filter.
  Future<void> loadGames({bool showLoading = true}) async {
    if (_isFetching) return;
    _isFetching = true;

    try {
      if (showLoading) {
        state = const AsyncValue.loading();
      }

      _allGames.clear();
      _offset = 0;
      _hasMore = true;

      await _fetchGames();

      final filter = _ref.read(premiumGamesFilterProvider(_type));
      state = AsyncValue.data(
        PremiumGamesState(
          games: _getFilteredGames(),
          filter: filter,
          isLoadingMore: false,
          hasMore: _hasMore,
        ),
      );
    } catch (e, stack) {
      debugPrint('[PremiumGames] Error loading games: $e');
      state = AsyncValue.error(e, stack);
    } finally {
      _isFetching = false;
    }
  }

  /// Load more games for pagination.
  Future<void> loadMore() async {
    if (_isFetching || !_hasMore) return;

    final currentState = state.valueOrNull;
    if (currentState == null) return;

    _isFetching = true;
    state = AsyncValue.data(currentState.copyWith(isLoadingMore: true));

    try {
      await _fetchGames();

      final filter = _ref.read(premiumGamesFilterProvider(_type));
      state = AsyncValue.data(
        PremiumGamesState(
          games: _getFilteredGames(),
          filter: filter,
          isLoadingMore: false,
          hasMore: _hasMore,
        ),
      );
    } catch (e) {
      debugPrint('[PremiumGames] Error loading more: $e');
      state = AsyncValue.data(currentState.copyWith(isLoadingMore: false));
    } finally {
      _isFetching = false;
    }
  }

  /// Fetch games from repository based on type.
  Future<void> _fetchGames() async {
    final repository = _ref.read(gameRepositoryProvider);
    late final _PremiumGamesFetch fetched;

    switch (_type) {
      case PremiumGamesType.favorites:
        fetched = await _fetchFavoriteGames(repository);
        break;
      case PremiumGamesType.countrymen:
        fetched = await _fetchCountrymenGames(repository);
        break;
      case PremiumGamesType.live:
        fetched = await _fetchLiveGames(repository);
        break;
      case PremiumGamesType.gm:
        fetched = await _fetchGmGames(repository);
        break;
      case PremiumGamesType.classical:
        fetched = await _fetchClassicalGames(repository);
        break;
    }

    _hasMore = fetched.hasMore;
    _offset = fetched.nextOffset;

    if (fetched.games.isNotEmpty) {
      _allGames.addAll(fetched.games);
      // Sort all games by datetime DESC, then avgElo DESC
      _sortGames();
    }

    debugPrint(
      '[PremiumGames] Fetched ${fetched.games.length} games, total: ${_allGames.length}, hasMore: $_hasMore',
    );
  }

  /// Fetch games for favorite players.
  Future<_PremiumGamesFetch> _fetchFavoriteGames(
    GameRepository repository,
  ) async {
    final favoritesAsync = _ref.read(favoritePlayersProviderNew);
    final favorites = favoritesAsync.valueOrNull ?? [];

    if (favorites.isEmpty) {
      debugPrint('[PremiumGames] No favorite players');
      return _emptyFetch();
    }

    // Get FIDE IDs from favorites
    final fideIds =
        favorites
            .where((f) => f.fideId != null && f.fideId!.isNotEmpty)
            .map((f) => f.fideId!)
            .toList();

    if (fideIds.isEmpty) {
      debugPrint('[PremiumGames] No FIDE IDs for favorites');
      return _emptyFetch();
    }

    debugPrint(
      '[PremiumGames] Fetching games for ${fideIds.length} favorite players',
    );

    try {
      final games = await repository.getGamesByMultipleFideIds(
        fideIds: fideIds,
        limit: _pageSize,
        offset: _offset,
      );

      return _PremiumGamesFetch(
        games: games.map((g) => GamesTourModel.fromGame(g)).toList(),
        hasMore: games.length >= _pageSize,
        nextOffset: _offset + games.length,
      );
    } catch (e) {
      debugPrint('[PremiumGames] Error fetching favorite games: $e');
      return _emptyFetch();
    }
  }

  /// Fetch games for countrymen.
  Future<_PremiumGamesFetch> _fetchCountrymenGames(
    GameRepository repository,
  ) async {
    final countryState = _ref.read(countryDropdownProvider);
    final country = countryState.value;

    if (country == null || country.countryCode.isEmpty) {
      debugPrint('[PremiumGames] No country selected');
      return _emptyFetch();
    }

    debugPrint(
      '[PremiumGames] Fetching games for country ${country.countryCode}',
    );

    try {
      final games = await repository.getGamesByCountryCodePaginated(
        countryCode: country.countryCode,
        limit: _pageSize,
        offset: _offset,
      );

      return _PremiumGamesFetch(
        games: games.map((g) => GamesTourModel.fromGame(g)).toList(),
        hasMore: games.length >= _pageSize,
        nextOffset: _offset + games.length,
      );
    } catch (e) {
      debugPrint('[PremiumGames] Error fetching countryman games: $e');
      return _emptyFetch();
    }
  }

  /// Fetch all live games globally.
  Future<_PremiumGamesFetch> _fetchLiveGames(GameRepository repository) async {
    return _fetchCurrentSmartEventGames(repository, liveOnly: true);
  }

  /// Fetch games with average rating >= 2500, matching the phone smart
  /// collection intent instead of the older "one player over 2500" fallback.
  Future<_PremiumGamesFetch> _fetchGmGames(GameRepository repository) async {
    return _fetchCurrentSmartEventGames(
      repository,
      minEventAverageElo: 2500,
      minGameAverageElo: 2500,
    );
  }

  /// Fetch classical/standard games globally.
  Future<_PremiumGamesFetch> _fetchClassicalGames(
    GameRepository repository,
  ) async {
    return _fetchCurrentSmartEventGames(
      repository,
      eventTimeControls: const [
        'standard',
        'classical',
        'Standard',
        'Classical',
      ],
    );
  }

  Future<_PremiumGamesFetch> _fetchCurrentSmartEventGames(
    GameRepository repository, {
    bool liveOnly = false,
    int? minEventAverageElo,
    int? minGameAverageElo,
    List<String>? eventTimeControls,
  }) async {
    const maxEmptyPages = 2;
    final games = <GamesTourModel>[];
    var hasMore = false;
    var nextOffset = _offset;
    var pageCount = 0;

    try {
      do {
        final page = await repository.getCurrentSmartEventGamesPage(
          liveOnly: liveOnly,
          minEventAverageElo: minEventAverageElo,
          minGameAverageElo: minGameAverageElo,
          eventTimeControls: eventTimeControls,
          limit: _pageSize,
          offset: nextOffset,
        );

        games.addAll(page.games.map((game) => GamesTourModel.fromGame(game)));
        hasMore = page.hasMore;
        nextOffset = page.nextOffset;
        pageCount++;
      } while (games.isEmpty && hasMore && pageCount < maxEmptyPages);

      return _PremiumGamesFetch(
        games: games,
        hasMore: hasMore,
        nextOffset: nextOffset,
      );
    } catch (e) {
      debugPrint('[PremiumGames] Error fetching smart event games: $e');
      return _emptyFetch();
    }
  }

  _PremiumGamesFetch _emptyFetch() {
    return _PremiumGamesFetch(
      games: const <GamesTourModel>[],
      hasMore: false,
      nextOffset: _offset,
    );
  }

  void _sortGames() {
    _allGames.sort((a, b) {
      if (_isCurrentSmartEventType) {
        final aDay = _smartGameDay(a);
        final bDay = _smartGameDay(b);
        final dayCompare = bDay.compareTo(aDay);
        if (dayCompare != 0) return dayCompare;

        final eloCompare = _avgElo(b).compareTo(_avgElo(a));
        if (eloCompare != 0) return eloCompare;

        return (b.lastMoveTime ?? DateTime(0)).compareTo(
          a.lastMoveTime ?? DateTime(0),
        );
      } else if (_type == PremiumGamesType.countrymen ||
          _type == PremiumGamesType.gm) {
        // For Countrymen: Primary is avgElo DESC, Secondary is lastMoveTime DESC
        final aElo = _avgElo(a);
        final bElo = _avgElo(b);
        final eloCompare = bElo.compareTo(aElo);
        if (eloCompare != 0) return eloCompare;

        return (b.lastMoveTime ?? DateTime(0)).compareTo(
          a.lastMoveTime ?? DateTime(0),
        );
      } else {
        // For Favorites: Primary is lastMoveTime DESC, Secondary is avgElo DESC
        final timeCompare = (b.lastMoveTime ?? DateTime(0)).compareTo(
          a.lastMoveTime ?? DateTime(0),
        );
        if (timeCompare != 0) return timeCompare;

        final aElo = _avgElo(a);
        final bElo = _avgElo(b);
        return bElo.compareTo(aElo);
      }
    });
  }

  /// Calculate average ELO for a game.
  int _avgElo(GamesTourModel game) {
    final white = game.whitePlayer.rating;
    final black = game.blackPlayer.rating;
    if (white == 0 && black == 0) return 0;
    if (white == 0) return black;
    if (black == 0) return white;
    return (white + black) ~/ 2;
  }

  DateTime _smartGameDay(GamesTourModel game) {
    final raw = game.lastMoveTime ?? game.bucketDate ?? DateTime(0);
    final local = raw.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// Get filtered games based on current filter.
  List<GamesTourModel> _getFilteredGames() {
    final filter = _ref.read(premiumGamesFilterProvider(_type));

    return _allGames.where((game) {
      if (_type == PremiumGamesType.live && !isPremiumLiveGame(game)) {
        return false;
      }

      // Smart event collections should never show tomorrow/future games.
      if (_type == PremiumGamesType.live ||
          _type == PremiumGamesType.gm ||
          _type == PremiumGamesType.classical) {
        final bucketDate = game.bucketDate;
        if (bucketDate != null) {
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final day = DateTime(
            bucketDate.year,
            bucketDate.month,
            bucketDate.day,
          );
          if (day.isAfter(today)) {
            return false;
          }
        }
      }

      // Date filter
      if (filter.dateRange.startDate != null) {
        final gameDate = game.lastMoveTime;
        if (gameDate == null ||
            gameDate.isBefore(filter.dateRange.startDate!)) {
          return false;
        }
      }

      // Result filter
      if (!filter.result.matches(game.effectiveGameStatus)) {
        return false;
      }

      // ELO filter
      final avgElo = _avgElo(game);
      if (filter.minElo != null && avgElo < filter.minElo!) {
        return false;
      }
      if (filter.maxElo != null && avgElo > filter.maxElo!) {
        return false;
      }

      return true;
    }).toList();
  }

  /// Apply new filter and update games.
  void applyFilter(PremiumGamesFilter filter) {
    _ref.read(premiumGamesFilterProvider(_type).notifier).state = filter;

    final currentState = state.valueOrNull;
    if (currentState == null) return;

    state = AsyncValue.data(
      PremiumGamesState(
        games: _getFilteredGames(),
        filter: filter,
        isLoadingMore: false,
        hasMore: _hasMore,
      ),
    );
  }

  /// Reset filter to defaults.
  void resetFilter() {
    applyFilter(PremiumGamesFilter.defaultFilter);
  }

  /// Refresh games (pull-to-refresh).
  Future<void> refresh() async {
    await loadGames(showLoading: false);
  }
}

@visibleForTesting
bool isPremiumLiveGame(GamesTourModel game) {
  if (!game.hasStarted || game.effectiveGameStatus != GameStatus.ongoing) {
    return false;
  }

  final whiteClock = game.whiteClockSeconds;
  final blackClock = game.blackClockSeconds;
  if (whiteClock == null || blackClock == null) return false;

  return whiteClock > 0 && blackClock > 0;
}
