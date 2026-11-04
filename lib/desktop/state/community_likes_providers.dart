import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/services/likes/community_likes_repository.dart';

/// What the Likes tab shows: the explanation, the ranked games or the
/// players in them.
enum CommunityLikesSection { about, games, players }

final communityLikesSectionProvider = StateProvider<CommunityLikesSection>(
  (ref) => CommunityLikesSection.games,
);

/// The ranking period the Likes tab shows. Starts on Week, like the phone.
final communityLikesPeriodProvider = StateProvider<CommunityLikesPeriod>(
  (ref) => CommunityLikesPeriod.week,
);

/// A day inside an earlier period the user stepped back to, or null to follow
/// the clock (the current period). Changing period clears it.
final communityLikesDayProvider = StateProvider<DateTime?>((ref) => null);

/// The query the Likes tab is reading right now.
CommunityLikesQuery communityLikesActiveQuery(WidgetRef ref, {DateTime? now}) {
  final period = ref.watch(communityLikesPeriodProvider);
  final day = ref.watch(communityLikesDayProvider);
  return CommunityLikesQuery(period, day ?? now ?? DateTime.now());
}

/// First page of a ranking. Kept warm for a few minutes after the tab stops
/// watching it, so flicking between periods does not refetch every time.
final communityLikesProvider = FutureProvider.autoDispose
    .family<CommunityLikesResult, CommunityLikesQuery>((ref, query) async {
      final link = ref.keepAlive();
      final expiry = Timer(const Duration(minutes: 5), link.close);
      ref.onDispose(expiry.cancel);
      try {
        return await ref.watch(communityLikesRepositoryProvider).fetch(query);
      } catch (_) {
        // A failure must be retried on the next watch, not cached.
        link.close();
        rethrow;
      }
    });

class CommunityLikesPagingState {
  const CommunityLikesPagingState({
    this.entries = const [],
    this.cursor,
    this.loading = false,
    this.failed = false,
  });

  /// Pages after the first, in rank order.
  final List<CommunityLikesEntry> entries;
  final CommunityLikesCursor? cursor;
  final bool loading;
  final bool failed;

  bool get hasMore => cursor != null;
}

/// Pages after the first, shared by Games and Players for one window.
final communityLikesPagesProvider = StateNotifierProvider.autoDispose.family<
  CommunityLikesPages,
  CommunityLikesPagingState,
  CommunityLikesQuery
>((ref, query) {
  final first = ref.watch(communityLikesProvider(query));
  final initial = first.isLoading || first.hasError ? null : first.valueOrNull;
  return CommunityLikesPages(
    initial?.nextCursor,
    (cursor) =>
        ref.read(communityLikesRepositoryProvider).fetch(query, after: cursor),
  );
});

class CommunityLikesPages extends StateNotifier<CommunityLikesPagingState> {
  CommunityLikesPages(CommunityLikesCursor? cursor, this._fetch)
    : super(CommunityLikesPagingState(cursor: cursor));

  final Future<CommunityLikesResult> Function(CommunityLikesCursor cursor)
  _fetch;

  Future<void> loadMore() async {
    final cursor = state.cursor;
    if (cursor == null || state.loading) return;
    final previous = state.entries;
    state = CommunityLikesPagingState(
      entries: previous,
      cursor: cursor,
      loading: true,
    );
    try {
      final page = await _fetch(cursor);
      if (!mounted) return;
      if (page.status != CommunityLikesStatus.ranked) {
        throw StateError('Ranking unavailable');
      }
      final seen = {for (final entry in previous) entry.game.gameId};
      state = CommunityLikesPagingState(
        entries: [
          ...previous,
          for (final entry in page.entries)
            if (seen.add(entry.game.gameId)) entry,
        ],
        cursor: page.nextCursor,
      );
    } catch (_) {
      if (mounted) {
        state = CommunityLikesPagingState(
          entries: previous,
          cursor: cursor,
          failed: true,
        );
      }
    }
  }
}
