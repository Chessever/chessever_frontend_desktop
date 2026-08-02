import 'dart:async';

import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
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

  /// Games with classical and standard time controls.
  classical,

  /// Games from the miniature database, ending by move 25.
  miniatures,
}

/// Whether [type] paginates one whole day at a time.
///
/// These collections are scoped to currently-running events, so the reader
/// walks backwards a day at a time: a day loads whole, then the next older day
/// appends beneath it. Every loaded day is therefore complete, which is why
/// their game counts are trustworthy before the feed is fully drained.
bool isDayPaginatedSmartGamesType(PremiumGamesType type) {
  return type == PremiumGamesType.live ||
      type == PremiumGamesType.gm ||
      type == PremiumGamesType.classical;
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
    this.timeControl = GameTimeControlFilter.all,
    this.eco = GameEcoFilter.all,
    this.finish = GameFinishFilter.all,
    this.minElo,
    this.maxElo,
    this.yearFrom,
    this.yearTo,
  });

  final PremiumGamesDateRange dateRange;
  final PremiumGamesResult result;
  final GameTimeControlFilter timeControl;
  final GameEcoFilter eco;
  final GameFinishFilter finish;
  final int? minElo;
  final int? maxElo;
  final int? yearFrom;
  final int? yearTo;

  bool get hasActiveFilters {
    return dateRange != PremiumGamesDateRange.allTime ||
        result != PremiumGamesResult.all ||
        timeControl != GameTimeControlFilter.all ||
        !eco.isAll ||
        finish != GameFinishFilter.all ||
        minElo != null ||
        maxElo != null ||
        yearFrom != null ||
        yearTo != null;
  }

  PremiumGamesFilter copyWith({
    PremiumGamesDateRange? dateRange,
    PremiumGamesResult? result,
    GameTimeControlFilter? timeControl,
    GameEcoFilter? eco,
    GameFinishFilter? finish,
    int? minElo,
    int? maxElo,
    bool clearElo = false,
    int? yearFrom,
    int? yearTo,
    bool clearYears = false,
  }) {
    return PremiumGamesFilter(
      dateRange: dateRange ?? this.dateRange,
      result: result ?? this.result,
      timeControl: timeControl ?? this.timeControl,
      eco: eco ?? this.eco,
      finish: finish ?? this.finish,
      minElo: clearElo ? null : (minElo ?? this.minElo),
      maxElo: clearElo ? null : (maxElo ?? this.maxElo),
      yearFrom: clearYears ? null : (yearFrom ?? this.yearFrom),
      yearTo: clearYears ? null : (yearTo ?? this.yearTo),
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

/// Provider for backend miniatures filter state.
final miniatureGamesFilterProvider = StateProvider<MiniatureGamesFilter>(
  (ref) => MiniatureGamesFilter.defaultFilter,
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

  /// Smart collections paginate one whole day per page, so these track the day
  /// cursor rather than a row offset.
  DateTime? _nextSmartEventDay;
  bool _smartEventDayCursorReady = false;

  /// Upper bound on days skipped in one fetch when a day survives the backend
  /// predicates but is emptied by the client-side narrowing.
  static const int _maxSkippedSmartEventDays = 5;
  static const Duration _smartEventRefreshInterval = Duration(minutes: 1);
  Timer? _smartEventRefreshTimer;

  Future<void> _initialize() async {
    await loadGames();
    _startSmartEventRefreshTimer();
  }

  bool get _isCurrentSmartEventType => isDayPaginatedSmartGamesType(_type);

  void _startSmartEventRefreshTimer() {
    if (!_isCurrentSmartEventType || _smartEventRefreshTimer != null) return;
    _smartEventRefreshTimer = Timer.periodic(_smartEventRefreshInterval, (_) {
      // Refresh only the newest day. Reloading the whole collection would
      // throw away every older day the reader had already scrolled into.
      unawaited(_refreshNewestSmartEventDay());
    });
  }

  /// Scope of the smart collection this notifier serves.
  ///
  /// Shared by the day probe, the day fetch and the periodic refresh so all
  /// three agree on which games belong to the collection.
  ({
    bool liveOnly,
    int? minEventAverageElo,
    int? minGameAverageElo,
    List<String>? eventTimeControls,
  })
  get _smartEventScope {
    return switch (_type) {
      PremiumGamesType.live => (
        liveOnly: true,
        minEventAverageElo: null,
        minGameAverageElo: null,
        eventTimeControls: null,
      ),
      PremiumGamesType.gm => (
        liveOnly: false,
        minEventAverageElo: 2500,
        minGameAverageElo: 2500,
        eventTimeControls: null,
      ),
      _ => (
        liveOnly: false,
        minEventAverageElo: null,
        minGameAverageElo: null,
        eventTimeControls: const ['standard', 'classical', 'Standard', 'Classical'],
      ),
    };
  }

  /// Reloads the newest day in place, leaving already-loaded older days alone.
  ///
  /// Older broadcast days are finished and never change; only the newest day
  /// carries live clocks and results worth re-reading.
  Future<void> _refreshNewestSmartEventDay() async {
    if (_isFetching) return;
    final currentState = state.valueOrNull;
    if (currentState == null) return;

    _isFetching = true;
    try {
      final repository = _ref.read(gameRepositoryProvider);
      final scope = _smartEventScope;
      final newestDay = await repository.getCurrentSmartEventDay(
        liveOnly: scope.liveOnly,
        minEventAverageElo: scope.minEventAverageElo,
        minGameAverageElo: scope.minGameAverageElo,
        eventTimeControls: scope.eventTimeControls,
      );
      if (newestDay == null) return;

      final page = await repository.getCurrentSmartEventGamesOnDay(
        day: newestDay,
        liveOnly: scope.liveOnly,
        minEventAverageElo: scope.minEventAverageElo,
        minGameAverageElo: scope.minGameAverageElo,
        eventTimeControls: scope.eventTimeControls,
      );

      // Swap that day's games wholesale. A day that has since rolled over is
      // simply a day nothing matches yet, and sorting floats it to the top.
      _allGames.removeWhere((game) => _smartGameDay(game) == newestDay);
      _allGames.addAll(page.games.map((game) => GamesTourModel.fromGame(game)));
      _sortGames();

      state = AsyncValue.data(
        PremiumGamesState(
          games: _getFilteredGames(),
          filter: _ref.read(premiumGamesFilterProvider(_type)),
          isLoadingMore: false,
          hasMore: _hasMore,
        ),
      );
    } catch (e) {
      debugPrint('[PremiumGames] Error refreshing newest smart day: $e');
    } finally {
      _isFetching = false;
    }
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
      _nextSmartEventDay = null;
      _smartEventDayCursorReady = false;

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
      case PremiumGamesType.miniatures:
        fetched = await _fetchMiniatures(_ref.read(gamebaseRepositoryProvider));
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
    return _fetchCurrentSmartEventGames(repository);
  }

  /// Fetch games with average rating >= 2500, matching the phone smart
  /// collection intent instead of the older "one player over 2500" fallback.
  Future<_PremiumGamesFetch> _fetchGmGames(GameRepository repository) async {
    return _fetchCurrentSmartEventGames(repository);
  }

  /// Fetch classical/standard games globally.
  Future<_PremiumGamesFetch> _fetchClassicalGames(
    GameRepository repository,
  ) async {
    return _fetchCurrentSmartEventGames(repository);
  }

  /// Load exactly one more day of the smart collection.
  ///
  /// The day is the unit of pagination: a fetch returns every game of a single
  /// day, never part of one, and never mixes two days. Scrolling to the bottom
  /// appends the next older day the same way.
  Future<_PremiumGamesFetch> _fetchCurrentSmartEventGames(
    GameRepository repository,
  ) async {
    final scope = _smartEventScope;

    try {
      var targetDay =
          _smartEventDayCursorReady
              ? _nextSmartEventDay
              : await repository.getCurrentSmartEventDay(
                liveOnly: scope.liveOnly,
                minEventAverageElo: scope.minEventAverageElo,
                minGameAverageElo: scope.minGameAverageElo,
                eventTimeControls: scope.eventTimeControls,
              );
      _smartEventDayCursorReady = true;

      if (targetDay == null) {
        _nextSmartEventDay = null;
        return _emptyFetch();
      }

      for (var skipped = 0; skipped <= _maxSkippedSmartEventDays; skipped++) {
        final page = await repository.getCurrentSmartEventGamesOnDay(
          day: targetDay!,
          liveOnly: scope.liveOnly,
          minEventAverageElo: scope.minEventAverageElo,
          minGameAverageElo: scope.minGameAverageElo,
          eventTimeControls: scope.eventTimeControls,
        );
        _nextSmartEventDay = page.nextDay;

        final games =
            page.games
                .map((game) => GamesTourModel.fromGame(game))
                .toList(growable: false);

        if (games.isNotEmpty) {
          return _PremiumGamesFetch(
            games: games,
            hasMore: page.hasMore,
            nextOffset: _offset,
          );
        }

        // The backend said this day had rows, but the client-side narrowing
        // emptied it. Walk on rather than showing an empty section.
        if (page.nextDay == null) {
          return const _PremiumGamesFetch(
            games: <GamesTourModel>[],
            hasMore: false,
            nextOffset: 0,
          );
        }
        targetDay = page.nextDay;
      }

      return _PremiumGamesFetch(
        games: const <GamesTourModel>[],
        hasMore: _nextSmartEventDay != null,
        nextOffset: _offset,
      );
    } catch (e) {
      debugPrint('[PremiumGames] Error fetching smart event day: $e');
      return _emptyFetch();
    }
  }

  Future<_PremiumGamesFetch> _fetchMiniatures(
    GamebaseRepository repository,
  ) async {
    try {
      final page = await repository.getMiniatures(
        filter: _ref.read(miniatureGamesFilterProvider),
        limit: _pageSize,
        offset: _offset,
      );
      final games = page.items.map(_miniatureToGame).toList(growable: false);
      final nextOffset = _offset + page.items.length;

      return _PremiumGamesFetch(
        games: games,
        hasMore: nextOffset < page.total && page.items.isNotEmpty,
        nextOffset: nextOffset,
      );
    } catch (e) {
      debugPrint('[PremiumGames] Error fetching miniatures: $e');
      return _emptyFetch();
    }
  }

  GamesTourModel _miniatureToGame(GamebaseMiniature miniature) {
    final whiteName = _cleanText(miniature.whiteName, fallback: 'White');
    final blackName = _cleanText(miniature.blackName, fallback: 'Black');
    final eventName = _cleanText(miniature.event, fallback: 'Miniatures');
    final result = GameStatus.fromString(miniature.result);
    final pgnResult = _pgnResult(result);
    final avgRating = _safeRating(miniature.avgRating);
    final eco = _cleanNullableText(miniature.eco);
    final openingName = _miniatureOpeningName(miniature);
    final roundSlug =
        eco ??
        (miniature.finalMoveNumber > 0
            ? '${miniature.finalMoveNumber} moves'
            : 'Miniature');

    return GamesTourModel(
      gameId: miniature.gameId,
      source: GameSource.gamebase,
      whitePlayer: PlayerCard(
        name: whiteName,
        federation: _cleanText(miniature.whiteFed),
        title: '',
        rating: _safeRating(miniature.whiteElo) ?? 0,
        countryCode: _cleanText(miniature.whiteFed),
        team: null,
        gamebasePlayerId: _cleanNullableText(miniature.whitePlayerId),
      ),
      blackPlayer: PlayerCard(
        name: blackName,
        federation: _cleanText(miniature.blackFed),
        title: '',
        rating: _safeRating(miniature.blackElo) ?? 0,
        countryCode: _cleanText(miniature.blackFed),
        team: null,
        gamebasePlayerId: _cleanNullableText(miniature.blackPlayerId),
      ),
      whiteTimeDisplay: '--:--',
      blackTimeDisplay: '--:--',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: result,
      roundId: 'gamebase-miniatures',
      roundSlug: roundSlug,
      tourId: '',
      tourName: eventName,
      eventName: eventName,
      pgn: _miniatureHeaderPgn(
        whiteName: whiteName,
        blackName: blackName,
        eventName: eventName,
        result: pgnResult,
        date: miniature.date,
        eco: eco,
        openingName: openingName,
        whiteElo: _safeRating(miniature.whiteElo),
        blackElo: _safeRating(miniature.blackElo),
        whiteFed: _cleanNullableText(miniature.whiteFed),
        blackFed: _cleanNullableText(miniature.blackFed),
      ),
      // Miniatures have no event board number; reuse this existing sortable
      // integer slot for the final move count so "fewest moves" stays local.
      boardNr: miniature.finalMoveNumber > 0 ? miniature.finalMoveNumber : null,
      lastMoveTime: miniature.date,
      dateStart: miniature.date,
      gameDay: miniature.date,
      eco: eco,
      openingName: openingName,
      timeControl: _cleanNullableText(miniature.timeControl),
      avgElo: avgRating,
      isOnline: miniature.isOnline,
    );
  }

  String _cleanText(String? value, {String fallback = ''}) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? fallback : trimmed;
  }

  String? _cleanNullableText(String? value) {
    final trimmed = _cleanText(value);
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _safeRating(int? value) {
    if (value == null || value <= 0 || value > 4000) return null;
    return value;
  }

  String _pgnResult(GameStatus status) {
    return switch (status) {
      GameStatus.whiteWins => '1-0',
      GameStatus.blackWins => '0-1',
      GameStatus.draw => '1/2-1/2',
      GameStatus.ongoing => '*',
      GameStatus.unknown => '*',
    };
  }

  String? _miniatureOpeningName(GamebaseMiniature miniature) {
    final opening = _cleanNullableText(miniature.opening);
    final variation = _cleanNullableText(miniature.variation);
    if (opening == null) return variation;
    return variation == null ? opening : '$opening: $variation';
  }

  String _pgnTagValue(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  String _miniatureHeaderPgn({
    required String whiteName,
    required String blackName,
    required String eventName,
    required String result,
    DateTime? date,
    String? eco,
    String? openingName,
    int? whiteElo,
    int? blackElo,
    String? whiteFed,
    String? blackFed,
  }) {
    final dateTag =
        date == null
            ? '????.??.??'
            : '${date.year.toString().padLeft(4, '0')}.'
                '${date.month.toString().padLeft(2, '0')}.'
                '${date.day.toString().padLeft(2, '0')}';
    final buffer =
        StringBuffer()
          ..writeln('[Event "${_pgnTagValue(eventName)}"]')
          ..writeln('[Date "$dateTag"]')
          ..writeln('[White "${_pgnTagValue(whiteName)}"]')
          ..writeln('[Black "${_pgnTagValue(blackName)}"]')
          ..writeln('[Result "$result"]');
    if (eco != null) {
      buffer.writeln('[ECO "${_pgnTagValue(eco)}"]');
    }
    if (openingName != null) {
      buffer.writeln('[Opening "${_pgnTagValue(openingName)}"]');
    }
    if (whiteElo != null) {
      buffer.writeln('[WhiteElo "$whiteElo"]');
    }
    if (blackElo != null) {
      buffer.writeln('[BlackElo "$blackElo"]');
    }
    if (whiteFed != null) {
      buffer.writeln('[WhiteFed "${_pgnTagValue(whiteFed)}"]');
    }
    if (blackFed != null) {
      buffer.writeln('[BlackFed "${_pgnTagValue(blackFed)}"]');
    }
    buffer
      ..writeln()
      ..write(result);
    return buffer.toString();
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
      if (_type == PremiumGamesType.miniatures) {
        final filter = _ref.read(miniatureGamesFilterProvider);
        final primaryCompare = switch (filter.sort) {
          MiniatureGamesSort.rating => _compareMiniatureValues(
            _miniatureRating(a),
            _miniatureRating(b),
            filter.order,
          ),
          MiniatureGamesSort.moves => _compareMiniatureValues(
            a.boardNr ?? 0,
            b.boardNr ?? 0,
            filter.order,
          ),
          MiniatureGamesSort.recent => _compareMiniatureDates(
            a.lastMoveTime,
            b.lastMoveTime,
            filter.order,
          ),
        };
        if (primaryCompare != 0) return primaryCompare;

        final dateCompare = _compareMiniatureDates(
          a.lastMoveTime,
          b.lastMoveTime,
          MiniatureGamesSortOrder.desc,
        );
        if (dateCompare != 0) return dateCompare;

        final eloCompare = _compareMiniatureValues(
          _miniatureRating(a),
          _miniatureRating(b),
          MiniatureGamesSortOrder.desc,
        );
        if (eloCompare != 0) return eloCompare;

        return a.gameId.compareTo(b.gameId);
      }

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

  int _compareMiniatureValues(int a, int b, MiniatureGamesSortOrder order) {
    return order == MiniatureGamesSortOrder.asc
        ? a.compareTo(b)
        : b.compareTo(a);
  }

  int _compareMiniatureDates(
    DateTime? a,
    DateTime? b,
    MiniatureGamesSortOrder order,
  ) {
    final aDate = a ?? DateTime(0);
    final bDate = b ?? DateTime(0);
    return order == MiniatureGamesSortOrder.asc
        ? aDate.compareTo(bDate)
        : bDate.compareTo(aDate);
  }

  int _miniatureRating(GamesTourModel game) {
    final avgElo = game.avgElo;
    return avgElo != null && avgElo > 0 ? avgElo : _avgElo(game);
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

  /// Day a game belongs to, keyed exactly the way the feed groups its sections
  /// so a day-page and its rendered section can never disagree.
  DateTime _smartGameDay(GamesTourModel game) {
    final raw = game.bucketDate ?? DateTime(0);
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

      if (filter.yearFrom != null || filter.yearTo != null) {
        final gameDate = game.lastMoveTime ?? game.bucketDate;
        if (gameDate == null) return false;
        final year = gameDate.year;
        if (filter.yearFrom != null && year < filter.yearFrom!) return false;
        if (filter.yearTo != null && year > filter.yearTo!) return false;
      }

      // Result filter
      if (!filter.result.matches(game.effectiveGameStatus)) {
        return false;
      }

      final gameFilter = GameFilter(
        result: GameResultFilter.all,
        timeControl: filter.timeControl,
        eco: filter.eco,
        finish: filter.finish,
      );
      if (!GameFilterHelper.applyFilter([game], gameFilter).contains(game)) {
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

  /// Apply backend miniatures filters and reload the miniature shelf.
  Future<void> applyMiniatureFilter(MiniatureGamesFilter filter) async {
    _ref.read(miniatureGamesFilterProvider.notifier).state = filter;
    await loadGames(showLoading: true);
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
