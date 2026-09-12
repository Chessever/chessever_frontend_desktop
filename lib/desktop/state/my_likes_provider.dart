import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/desktop_local_day_clock.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/liked_games/liked_analyses_query.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/library/utils/saved_analysis_converters.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

/// Section key used when an explicit sort is active: the list reads as one
/// ordered result instead of being regrouped by liked-at day.
const String kMyLikesSortedSectionKey = '__sorted__';

/// Section key for rows with no usable date.
const String kMyLikesUnknownDateKey = '0000-00-00';

/// When a like was made, in LOCAL time. Supabase returns `created_at` as UTC;
/// the seven-day window and the day sections are both local calendar days.
DateTime likedAtOf(SavedAnalysis analysis) => analysis.createdAt.toLocal();

/// Request context for [action] on one liked row.
///
/// The Likes window decides every content action (open, preview navigation,
/// edit, copy, share, export, move). Owning the row does not bypass it.
/// Capacity for moving or copying a like into a regular database is checked
/// separately by the save guard, so this context spends no quota: the decision
/// is the window alone.
DesktopAccessContext likedGameAccessContext(
  SavedAnalysis analysis,
  DesktopAction action,
) {
  return DesktopAccessContext(
    feature: DesktopFeature.likes,
    action: action,
    origin: DesktopDiscoveryOrigin.likes,
    ownedDocument: true,
    retainedSaveId: analysis.id.isEmpty ? null : analysis.id,
    contentDate: likedAtOf(analysis),
    quota: DesktopQuota.none,
  );
}

DesktopAccessDecision likedGameDecision(
  SavedAnalysis analysis,
  DesktopAction action, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  return evaluateDesktopAccess(
    context: likedGameAccessContext(analysis, action),
    subscription: subscription,
    entitlement: entitlement,
    now: now,
  );
}

/// One liked game prepared for the My Likes list.
@immutable
class MyLikesEntry {
  const MyLikesEntry({
    required this.analysis,
    required this.game,
    required this.likedAt,
    required this.access,
  });

  final SavedAnalysis analysis;
  final GamesTourModel game;

  /// When the user liked this game, local time.
  final DateTime likedAt;

  /// Outcome for opening this like when the view was derived. Re-evaluated at
  /// tap time and export time; this value only drives what is drawn at rest.
  final DesktopAccess access;

  /// Drawn locked: the entitlement is KNOWN and the like is outside the free
  /// window. A membership that is still loading is not drawn locked, so a
  /// member never sees a lock flash on a cold start.
  bool get isLocked => access == DesktopAccess.premiumRequired;
}

/// The derived My Likes view.
@immutable
class MyLikesData {
  const MyLikesData({
    required this.sections,
    required this.openableAnalyses,
    required this.totalLiked,
    required this.visibleCount,
    required this.lockedCount,
  });

  /// `yyyy-MM-dd` liked-at day (newest first), or a single
  /// [kMyLikesSortedSectionKey] bucket when an explicit sort is active.
  final List<MapEntry<String, List<MyLikesEntry>>> sections;

  /// Visible order with every not-allowed entry excluded. This is the game
  /// list handed to the board, so stepping between games cannot cross the
  /// window.
  final List<SavedAnalysis> openableAnalyses;

  /// Likes in the collection before search and filters.
  final int totalLiked;

  /// Entries surviving search and filters.
  final int visibleCount;

  /// Visible entries drawn locked.
  final int lockedCount;

  bool get isEmpty => totalLiked == 0 && visibleCount == 0;
  bool get hasNoMatches => !isEmpty && visibleCount == 0;
}

/// Buckets entries into liked-at day sections, newest day first. Entry order
/// within a day is preserved (the query already returns newest-liked first).
List<MapEntry<String, List<MyLikesEntry>>> groupEntriesByLikedAt(
  List<MyLikesEntry> entries,
) {
  final grouped = <String, List<MyLikesEntry>>{};
  final format = DateFormat('yyyy-MM-dd');
  for (final entry in entries) {
    final key = format.format(entry.likedAt);
    grouped.putIfAbsent(key, () => <MyLikesEntry>[]).add(entry);
  }
  final keys =
      grouped.keys.toList()..sort((a, b) {
        if (a == kMyLikesUnknownDateKey) return 1;
        if (b == kMyLikesUnknownDateKey) return -1;
        return b.compareTo(a);
      });
  return [for (final key in keys) MapEntry(key, grouped[key]!)];
}

/// Pure derivation of the My Likes view from query results and entitlement.
MyLikesData buildMyLikesData({
  required List<SavedAnalysis> analyses,
  required int totalLiked,
  required LikedAnalysesQuery query,
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final entries = [
    for (final analysis in analyses)
      MyLikesEntry(
        analysis: analysis,
        game: savedAnalysisToCardGame(analysis),
        likedAt: likedAtOf(analysis),
        access:
            likedGameDecision(
              analysis,
              DesktopAction.openContent,
              subscription: subscription,
              entitlement: entitlement,
              now: at,
            ).outcome,
      ),
  ];

  final sections =
      query.hasExplicitSort
          ? (entries.isEmpty
              ? const <MapEntry<String, List<MyLikesEntry>>>[]
              : [MapEntry(kMyLikesSortedSectionKey, entries)])
          : groupEntriesByLikedAt(entries);

  final openable = <SavedAnalysis>[];
  var locked = 0;
  for (final section in sections) {
    for (final entry in section.value) {
      if (entry.access == DesktopAccess.allowed) openable.add(entry.analysis);
      if (entry.isLocked) locked += 1;
    }
  }

  return MyLikesData(
    sections: sections,
    openableAnalyses: List<SavedAnalysis>.unmodifiable(openable),
    totalLiked: totalLiked,
    visibleCount: entries.length,
    lockedCount: locked,
  );
}

/// The likes that may be opened RIGHT NOW, in [visibleOrder]. Called at tap
/// time, because the app can sit open across local midnight or through a
/// membership change between drawing a row and clicking it.
List<SavedAnalysis> openableLikedAnalyses(
  Iterable<SavedAnalysis> visibleOrder, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return [
    for (final analysis in visibleOrder)
      if (likedGameDecision(
        analysis,
        DesktopAction.openContent,
        subscription: subscription,
        entitlement: entitlement,
        now: at,
      ).isAllowed)
        analysis,
  ];
}

/// Export split, evaluated at export time.
@immutable
class LikedGamesExportSlice {
  const LikedGamesExportSlice({
    required this.accessible,
    required this.locked,
    required this.undetermined,
  });

  /// Likes that may be exported now (everything, for a member).
  final List<SavedAnalysis> accessible;

  /// Likes outside the free window with a KNOWN free entitlement.
  final int locked;

  /// Likes whose access could not be decided (membership loading or
  /// unreachable). Never exported and never upsold; the caller offers Retry.
  final int undetermined;

  bool get isComplete => locked == 0 && undetermined == 0;
}

LikedGamesExportSlice likedGamesExportSlice(
  Iterable<SavedAnalysis> analyses, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final accessible = <SavedAnalysis>[];
  var locked = 0;
  var undetermined = 0;
  for (final analysis in analyses) {
    final outcome =
        likedGameDecision(
          analysis,
          DesktopAction.export,
          subscription: subscription,
          entitlement: entitlement,
          now: at,
        ).outcome;
    switch (outcome) {
      case DesktopAccess.allowed:
        accessible.add(analysis);
      case DesktopAccess.premiumRequired:
        locked += 1;
      case DesktopAccess.checking:
      case DesktopAccess.accountRequired:
      case DesktopAccess.quotaExceeded:
      case DesktopAccess.temporarilyUnavailable:
        undetermined += 1;
    }
  }
  return LikedGamesExportSlice(
    accessible: List<SavedAnalysis>.unmodifiable(accessible),
    locked: locked,
    undetermined: undetermined,
  );
}

/// Formats a `yyyy-MM-dd` liked-at key as Today / Yesterday / `EEEE, MMM d`
/// in local time. 'Unknown date' for the sentinel key.
///
/// Yesterday is computed with calendar arithmetic, so the label stays right on
/// the day after a daylight-saving change (a 24-hour subtraction from local
/// midnight lands on the wrong day there).
String formatLikedDateHeader(String dateKey, {DateTime? now}) {
  if (dateKey == kMyLikesUnknownDateKey) return 'Unknown date';
  final date = DateTime.tryParse(dateKey);
  if (date == null) return dateKey;

  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final yesterday = DateTime(clock.year, clock.month, clock.day - 1);
  final day = DateTime(date.year, date.month, date.day);

  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return DateFormat('EEEE, MMM d').format(date);
}

class MyLikesQueryNotifier extends StateNotifier<LikedAnalysesQuery> {
  MyLikesQueryNotifier() : super(const LikedAnalysesQuery());

  void setSearch(String value) {
    final next = value.trim();
    if (next == state.search) return;
    state = state.copyWith(search: next);
  }

  void clearSearch() => setSearch('');

  /// Empty selection = no tag filter.
  void toggleTag(String tag) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return;
    final next = <String>{...state.tags};
    if (!next.add(trimmed)) next.remove(trimmed);
    state = state.copyWith(tags: Set<String>.unmodifiable(next));
  }

  void clearTags() => state = state.copyWith(tags: const <String>{});

  void setResult(LikedGamesResultFilter result) =>
      state = state.copyWith(result: result);

  void setTimeControl(LikedGamesTimeControlFilter timeControl) =>
      state = state.copyWith(timeControl: timeControl);

  void setSort(LikedGamesSort sort) => state = state.copyWith(sort: sort);

  void clearAll() => state = const LikedAnalysesQuery();
}

final myLikesQueryProvider =
    StateNotifierProvider.autoDispose<MyLikesQueryNotifier, LikedAnalysesQuery>(
      (ref) => MyLikesQueryNotifier(),
    );

/// Server rows for the active query. Re-runs whenever the query changes and
/// after like, unlike and tag writes, so a removed like never lingers.
final myLikesRowsProvider = FutureProvider.autoDispose<List<SavedAnalysis>>((
  ref,
) async {
  final repo = ref.watch(libraryRepositoryProvider);
  final query = ref.watch(myLikesQueryProvider);
  ref.watch(likedGamesProvider.select((value) => value.valueOrNull));
  final folder = await ref.watch(likedGamesFolderProvider.future);
  return repo.getLikedAnalysesForView(folderId: folder.id, query: query);
});

/// Tag -> number of likes carrying it, across the whole collection.
final myLikesTagCountsProvider = Provider.autoDispose<Map<String, int>>((ref) {
  final likes = ref.watch(likedGamesProvider).valueOrNull;
  final counts = <String, int>{};
  for (final analysis in likes ?? const <SavedAnalysis>[]) {
    for (final raw in analysis.tags) {
      final tag = raw.trim();
      if (tag.isEmpty) continue;
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  return counts;
});

/// The derived view. Access is recomputed without refetching when the
/// membership changes, at local midnight, and when the app resumes.
final myLikesViewProvider = Provider.autoDispose<AsyncValue<MyLikesData>>((
  ref,
) {
  final rows = ref.watch(myLikesRowsProvider);
  final query = ref.watch(myLikesQueryProvider);
  final subscription = ref.watch(subscriptionProvider);
  final entitlement = ref.watch(desktopEntitlementProvider);
  ref.watch(desktopLocalDayProvider);
  final total = ref.watch(likedGamesProvider).valueOrNull?.length;
  return rows.whenData(
    (analyses) => buildMyLikesData(
      analyses: analyses,
      totalLiked: total ?? analyses.length,
      query: query,
      subscription: subscription,
      entitlement: entitlement,
    ),
  );
});
