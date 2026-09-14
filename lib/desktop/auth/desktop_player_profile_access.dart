/// Player-profile game filters on desktop.
///
/// One active criterion is free; two or more combined are Premium. The gate
/// lives in a notifier override (installed on every desktop root container),
/// so EVERY entry point is covered: the six setters, `mergeFilter`, and the
/// page loads that would run a combined query (`loadMore`, `refresh`,
/// `loadAllRemainingPages`). Clearing filters is always free.
library;

import 'package:flutter/widgets.dart' show VoidCallback;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// Active criteria on a player's games list. Text search counts on this
/// surface (see `DesktopAccessContext.filterCriteriaCount`).
int desktopProfileFilterCriteria(
  GameFilter filter, {
  required String searchQuery,
  required PlayerResultFilter playerResult,
}) {
  final defaults = GameFilter.defaultFilter();
  var count = 0;
  if (filter.result != defaults.result) count++;
  if (filter.color != defaults.color) count++;
  if (filter.finish != defaults.finish) count++;
  if (filter.timeControl != defaults.timeControl) count++;
  if (filter.online != defaults.online) count++;
  if (filter.eco != defaults.eco) count++;
  if (filter.minYear != defaults.minYear ||
      filter.maxYear != defaults.maxYear) {
    count++;
  }
  if (filter.minRating != defaults.minRating ||
      filter.maxRating != defaults.maxRating) {
    count++;
  }
  if (searchQuery.trim().isNotEmpty) count++;
  if (playerResult != PlayerResultFilter.all) count++;
  return count;
}

DesktopAccessContext desktopProfileFilterContext(int criteria) =>
    DesktopAccessContext(
      feature: DesktopFeature.playerProfile,
      action: DesktopAction.filter,
      origin: DesktopDiscoveryOrigin.playerProfile,
      filterCriteriaCount: criteria,
    );

class DesktopPlayerProfileGamesNotifier extends PlayerProfileGamesNotifier {
  DesktopPlayerProfileGamesNotifier(
    super.ref,
    super.playerKey, {
    required ProviderContainer container,
  }) : _container = container;

  final ProviderContainer _container;

  int _criteriaFor({
    GameFilter? filter,
    String? searchQuery,
    PlayerResultFilter? playerResult,
  }) => desktopProfileFilterCriteria(
    filter ?? state.filter,
    searchQuery: searchQuery ?? state.searchQuery,
    playerResult: playerResult ?? state.playerResultFilter,
  );

  /// A filter change the user made. Denied => the current filter stays and
  /// no query runs; a verified purchase replays the change once.
  void _gate(int prospective, VoidCallback apply) {
    if (prospective < 2) {
      apply();
      return;
    }
    final admitted = admitDesktopAction(
      _container,
      desktopProfileFilterContext(prospective),
      surface: 'player_profile_filter',
      resume: DesktopAccessResume(
        run: () {
          if (mounted) apply();
        },
      ),
    );
    if (admitted) apply();
  }

  /// Page loads are not user filter changes: never a paywall, just no query
  /// for a combination the membership does not cover (a restored or
  /// downgraded state).
  bool get _currentQueryAdmitted {
    final criteria = _criteriaFor();
    if (criteria < 2) return true;
    return readDesktopAccess(
      _container.read,
      desktopProfileFilterContext(criteria),
    ).isAllowed;
  }

  @override
  void applyFilter(GameFilter filter) =>
      _gate(_criteriaFor(filter: filter), () => super.applyFilter(filter));

  @override
  void setTimeControlFilter(GameTimeControlFilter timeControl) => _gate(
    _criteriaFor(filter: state.filter.copyWith(timeControl: timeControl)),
    () => super.setTimeControlFilter(timeControl),
  );

  @override
  void setColorFilter(GameColorFilter color) => _gate(
    _criteriaFor(filter: state.filter.copyWith(color: color)),
    () => super.setColorFilter(color),
  );

  @override
  void setEcoFilter(GameEcoFilter eco) => _gate(
    _criteriaFor(filter: state.filter.copyWith(eco: eco)),
    () => super.setEcoFilter(eco),
  );

  @override
  void setResultFilter(GameResultFilter result) => _gate(
    _criteriaFor(filter: state.filter.copyWith(result: result)),
    () => super.setResultFilter(result),
  );

  @override
  void mergeFilter({
    GameTimeControlFilter? timeControl,
    GameColorFilter? color,
    GameEcoFilter? eco,
    GameOnlineFilter? online,
    GameResultFilter? result,
    PlayerResultFilter? playerResultFilter,
    String? searchQuery,
  }) => _gate(
    _criteriaFor(
      filter: state.filter.copyWith(
        timeControl: timeControl,
        color: color,
        eco: eco,
        online: online,
        result: result,
      ),
      searchQuery: searchQuery,
      playerResult: playerResultFilter,
    ),
    () => super.mergeFilter(
      timeControl: timeControl,
      color: color,
      eco: eco,
      online: online,
      result: result,
      playerResultFilter: playerResultFilter,
      searchQuery: searchQuery,
    ),
  );

  @override
  void setSearchQuery(String query) {
    if (state.searchQuery == query) return;
    _gate(
      _criteriaFor(searchQuery: query),
      () => super.setSearchQuery(query),
    );
  }

  @override
  void setPlayerResultFilter(PlayerResultFilter filter) => _gate(
    _criteriaFor(playerResult: filter),
    () => super.setPlayerResultFilter(filter),
  );

  @override
  Future<void> loadMore() async {
    if (!_currentQueryAdmitted) return;
    await super.loadMore();
  }

  @override
  Future<void> refresh() async {
    if (!_currentQueryAdmitted) return;
    await super.refresh();
  }

  @override
  Future<int> loadAllRemainingPages({int maxPages = 250}) async {
    if (!_currentQueryAdmitted) return 0;
    return super.loadAllRemainingPages(maxPages: maxPages);
  }
}

/// Installed on every desktop root `ProviderContainer`.
final Override desktopPlayerProfileGamesOverride = playerProfileGamesKeyProvider
    .overrideWith(
      (ref, playerKey) => DesktopPlayerProfileGamesNotifier(
        ref,
        playerKey,
        container: ref.container,
      ),
    );
