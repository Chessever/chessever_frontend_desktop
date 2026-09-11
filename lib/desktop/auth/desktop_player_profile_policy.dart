import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

final desktopProfileFilterPaywallProvider = StateProvider<int>((_) => 0);

/// Phone permits one active criterion; search and player-result each count.
/// All Desktop profile entry points share this notifier override, including
/// restored/detached tabs and Overview-to-Games shortcuts.
class DesktopPlayerProfileGamesNotifier extends PlayerProfileGamesNotifier {
  DesktopPlayerProfileGamesNotifier(this.ref, PlayerProfileKey key)
    : super(ref, key);
  final Ref ref;

  bool _accept(GameFilter filter, {PlayerResultFilter? result, String? query}) {
    final count =
        filter.activeFilterCount +
        ((result ?? state.playerResultFilter) == PlayerResultFilter.all
            ? 0
            : 1) +
        ((query ?? state.searchQuery).isEmpty ? 0 : 1);
    if (count <= 1 ||
        ref.read(desktopPremiumAccessProvider) == DesktopAccess.allowed) {
      return true;
    }
    ref.read(desktopProfileFilterPaywallProvider.notifier).state++;
    return false;
  }

  @override
  void applyFilter(GameFilter filter) {
    if (_accept(filter)) super.applyFilter(filter);
  }

  @override
  void setTimeControlFilter(GameTimeControlFilter timeControl) =>
      mergeFilter(timeControl: timeControl);
  @override
  void setColorFilter(GameColorFilter color) => mergeFilter(color: color);
  @override
  void setEcoFilter(GameEcoFilter eco) => mergeFilter(eco: eco);
  @override
  void setResultFilter(GameResultFilter result) => mergeFilter(result: result);
  @override
  void setPlayerResultFilter(PlayerResultFilter filter) =>
      mergeFilter(playerResultFilter: filter);
  @override
  void setSearchQuery(String query) => mergeFilter(searchQuery: query);
  @override
  void mergeFilter({
    GameTimeControlFilter? timeControl,
    GameColorFilter? color,
    GameEcoFilter? eco,
    GameOnlineFilter? online,
    GameResultFilter? result,
    PlayerResultFilter? playerResultFilter,
    String? searchQuery,
  }) {
    final next = state.filter.copyWith(
      timeControl: timeControl,
      color: color,
      eco: eco,
      online: online,
      result: result,
    );
    if (!_accept(next, result: playerResultFilter, query: searchQuery)) return;
    super.mergeFilter(
      timeControl: timeControl,
      color: color,
      eco: eco,
      online: online,
      result: result,
      playerResultFilter: playerResultFilter,
      searchQuery: searchQuery,
    );
  }

  bool get _canLoad =>
      state.activeFilterCount <= 1 ||
      ref.read(desktopPremiumAccessProvider) == DesktopAccess.allowed;
  @override
  Future<void> loadMore() async {
    if (_canLoad) await super.loadMore();
  }

  @override
  Future<void> refresh() async {
    if (_canLoad) await super.refresh();
  }

  @override
  Future<int> loadAllRemainingPages({int maxPages = 250}) async {
    if (ref.read(desktopPremiumAccessProvider) != DesktopAccess.allowed) {
      ref.read(desktopProfileFilterPaywallProvider.notifier).state++;
      return state.allGames.length;
    }
    return super.loadAllRemainingPages(maxPages: maxPages);
  }
}

final desktopPlayerProfileGamesOverride = playerProfileGamesKeyProvider
    .overrideWith((ref, key) => DesktopPlayerProfileGamesNotifier(ref, key));
