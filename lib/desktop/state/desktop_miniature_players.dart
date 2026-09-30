import 'package:flutter/foundation.dart' show immutable, setEquals;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/miniatures/miniature_players.dart';
import 'package:chessever/repository/supabase/chess_player/chess_player_repository.dart';

/// Query for the Miniatures Players view: title chips and a name search.
///
/// There is no sort. Mobile's games/wins/fastest sort was written into its
/// query and never read: ranking always comes from `chess_players` by rating.
@immutable
class DesktopMiniaturePlayersQuery {
  const DesktopMiniaturePlayersQuery({
    this.titles = const <MiniaturePlayerTitle>{},
    this.search = '',
  });

  final Set<MiniaturePlayerTitle> titles;
  final String search;

  DesktopMiniaturePlayersQuery copyWith({
    Set<MiniaturePlayerTitle>? titles,
    String? search,
  }) {
    return DesktopMiniaturePlayersQuery(
      titles: titles ?? this.titles,
      search: search ?? this.search,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopMiniaturePlayersQuery &&
          other.search == search &&
          setEquals(other.titles, titles);

  @override
  int get hashCode => Object.hash(search, Object.hashAllUnordered(titles));
}

final desktopMiniaturePlayersQueryProvider =
    StateProvider.autoDispose<DesktopMiniaturePlayersQuery>(
      (ref) => const DesktopMiniaturePlayersQuery(),
    );

@immutable
class DesktopMiniaturePlayersState {
  const DesktopMiniaturePlayersState({
    this.items = const <ChessPlayer>[],
    this.isLoading = false,
    this.hasMore = true,
    this.error,
  });

  final List<ChessPlayer> items;
  final bool isLoading;
  final bool hasMore;
  final Object? error;

  DesktopMiniaturePlayersState copyWith({
    List<ChessPlayer>? items,
    bool? isLoading,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) {
    return DesktopMiniaturePlayersState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : error ?? this.error,
    );
  }
}

/// Offset-paginated rating leaderboard. Recreated whenever the query changes,
/// so a title chip or search re-runs the query instead of filtering rows that
/// are already drawn.
final desktopMiniaturePlayersProvider = StateNotifierProvider.autoDispose<
  DesktopMiniaturePlayersNotifier,
  DesktopMiniaturePlayersState
>((ref) {
  final query = ref.watch(desktopMiniaturePlayersQueryProvider);
  return DesktopMiniaturePlayersNotifier(
    ref.read(chessPlayerRepositoryProvider),
    query,
  );
});

class DesktopMiniaturePlayersNotifier
    extends StateNotifier<DesktopMiniaturePlayersState> {
  DesktopMiniaturePlayersNotifier(this._repo, this._query)
    : super(const DesktopMiniaturePlayersState(isLoading: true)) {
    _fetch(reset: true);
  }

  static const int pageSize = 30;

  final ChessPlayerRepository _repo;
  final DesktopMiniaturePlayersQuery _query;
  int _seq = 0;

  Future<void> refresh() => _fetch(reset: true);

  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore) return;
    await _fetch(reset: false);
  }

  Future<void> _fetch({required bool reset}) async {
    final seq = ++_seq;
    final offset = reset ? 0 : state.items.length;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final titles =
          _query.titles.isEmpty
              ? null
              : _query.titles.map((title) => title.apiValue);
      final search = _query.search.trim();
      final page =
          search.isEmpty
              ? await _repo.getTopPlayers(
                limit: pageSize,
                offset: offset,
                titles: titles,
              )
              : await _repo.searchAllPlayers(
                query: search,
                limit: pageSize,
                offset: offset,
                titles: titles,
              );
      if (!mounted || seq != _seq) return;
      state = DesktopMiniaturePlayersState(
        items: reset ? page : [...state.items, ...page],
        isLoading: false,
        hasMore: page.length >= pageSize,
      );
    } catch (error) {
      if (!mounted || seq != _seq) return;
      state = state.copyWith(
        isLoading: false,
        hasMore: reset ? false : state.hasMore,
        error: error,
      );
    }
  }
}

/// Settled lookups (including confirmed misses) by FIDE id, so rows scrolled
/// back into view and a scorecard opened from a row share one request.
final Map<int, MiniaturePlayer?> _recordCache = <int, MiniaturePlayer?>{};
final Map<int, Future<MiniaturePlayer?>> _recordInFlight =
    <int, Future<MiniaturePlayer?>>{};

void clearDesktopMiniaturePlayerRecordCacheForTest() {
  _recordCache.clear();
  _recordInFlight.clear();
}

/// The gamebase record (W-L, player id) behind one rating-ranked player. FIDE
/// id first, then full name, then surname. Network errors stay uncached so a
/// refresh can retry.
Future<MiniaturePlayer?> resolveDesktopMiniaturePlayerRecord({
  required GamebaseRepository repo,
  required int fideId,
  required String name,
}) {
  if (_recordCache.containsKey(fideId)) {
    return Future.value(_recordCache[fideId]);
  }
  final pending = _recordInFlight[fideId];
  if (pending != null) return pending;

  Future<MiniaturePlayer?> lookup() async {
    final trimmed = name.trim();
    Future<MiniaturePlayer?> find(String search, int limit) async {
      final page = await repo.getMiniaturePlayers(search: search, limit: limit);
      return matchMiniaturePlayerRecord(
        candidates: page.items,
        fideId: fideId,
        name: trimmed,
      );
    }

    var record = await find(fideId.toString(), 5);
    if (record == null && trimmed.isNotEmpty) record = await find(trimmed, 10);
    final surname = trimmed.split(',').first.trim();
    if (record == null && surname.isNotEmpty && surname != trimmed) {
      record = await find(surname, 30);
    }
    _recordCache[fideId] = record;
    return record;
  }

  final future = lookup();
  _recordInFlight[fideId] = future;
  return future.whenComplete(() => _recordInFlight.remove(fideId));
}

final desktopMiniaturePlayerRecordProvider = FutureProvider.autoDispose
    .family<MiniaturePlayer?, ({int fideId, String name})>((ref, key) {
      return resolveDesktopMiniaturePlayerRecord(
        repo: ref.read(gamebaseRepositoryProvider),
        fideId: key.fideId,
        name: key.name,
      );
    });
