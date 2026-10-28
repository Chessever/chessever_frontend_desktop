import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/state/my_likes_provider.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/liked_games/liked_analyses_query.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgn =
    '[White "Carlsen, Magnus"]\n[Black "Nakamura, Hikaru"]\n'
    '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0';

SavedAnalysis _like(String id, DateTime likedAt) => SavedAnalysis(
  id: id,
  userId: 'user-1',
  folderId: 'likes',
  title: 'Carlsen vs Nakamura',
  sourceGameId: 'game-$id',
  chessGame: ChessGame.fromPgn('game-$id', _pgn),
  analysisState: const {},
  variationComments: const {},
  lastViewedPosition: -1,
  tags: const [],
  isFavorite: false,
  createdAt: likedAt,
  updatedAt: likedAt,
);

final _free = SubscriptionState();
final _loading = SubscriptionState(isLoading: true);
final _premium = SubscriptionState(isSubscribed: true);
final _unknown = SubscriptionState(error: 'offline');
const _guest = DesktopEntitlementSnapshot.guest;

DesktopAccess _open(
  SavedAnalysis like,
  DateTime now, {
  SubscriptionState? subscription,
  DesktopAction action = DesktopAction.openContent,
}) =>
    likedGameDecision(
      like,
      action,
      subscription: subscription ?? _free,
      entitlement: _guest,
      now: now,
    ).outcome;

void main() {
  final now = DateTime(2026, 9, 12, 15, 0);

  group('Likes seven-day window (liked-at, local calendar days)', () {
    test('liked on day 6 opens free, day 7 is locked', () {
      final day6 = _like('a', DateTime(2026, 9, 6, 9, 0));
      final day7 = _like('b', DateTime(2026, 9, 5, 23, 59));
      expect(_open(day6, now), DesktopAccess.allowed);
      expect(_open(day7, now), DesktopAccess.premiumRequired);
    });

    test('counts calendar days, not 168 hours, across local midnight', () {
      final lateSixDaysAgo = _like('a', DateTime(2026, 9, 6, 23, 50));
      final justAfterMidnight = DateTime(2026, 9, 12, 0, 10);
      expect(_open(lateSixDaysAgo, justAfterMidnight), DesktopAccess.allowed);
      // The next midnight moves the window even though under 168h elapsed.
      expect(
        _open(lateSixDaysAgo, DateTime(2026, 9, 13, 0, 1)),
        DesktopAccess.premiumRequired,
      );
    });

    test('holds across a daylight-saving change', () {
      // US DST starts 2026-03-08; calendar arithmetic ignores the lost hour.
      final dstNow = DateTime(2026, 3, 14, 0, 30);
      expect(
        _open(_like('a', DateTime(2026, 3, 8, 0, 30)), dstNow),
        DesktopAccess.allowed,
      );
      expect(
        _open(_like('b', DateTime(2026, 3, 7, 23, 30)), dstNow),
        DesktopAccess.premiumRequired,
      );
    });

    test('Supabase UTC created_at is judged on the local calendar day', () {
      final utc = DateTime(2026, 9, 6, 12).toUtc();
      final like = _like('a', utc);
      expect(likedAtOf(like).isUtc, isFalse);
      expect(_open(like, now), DesktopAccess.allowed);
    });

    test('a loading membership is never drawn locked', () {
      final old = _like('a', DateTime(2026, 8, 1));
      final data = buildMyLikesData(
        analyses: [old],
        totalLiked: 1,
        query: const LikedAnalysesQuery(),
        subscription: _loading,
        entitlement: _guest,
        now: now,
      );
      expect(data.sections.single.value.single.isLocked, isFalse);
      expect(data.lockedCount, 0);
      // Unknown never unlocks: it is not openable until the answer arrives.
      expect(data.openableAnalyses, isEmpty);
    });

    test('Premium opens every like; tag and remove are never gated', () {
      final old = _like('a', DateTime(2020, 1, 1));
      expect(_open(old, now, subscription: _premium), DesktopAccess.allowed);
      expect(_open(old, now, action: DesktopAction.tag), DesktopAccess.allowed);
      expect(
        _open(old, now, action: DesktopAction.remove),
        DesktopAccess.allowed,
      );
      expect(
        _open(old, now, action: DesktopAction.sort),
        DesktopAccess.allowed,
      );
      expect(
        _open(old, now, action: DesktopAction.filter),
        DesktopAccess.allowed,
      );
    });

    test('owning the like row does not bypass the window', () {
      final old = _like('a', DateTime(2026, 8, 1));
      final context = likedGameAccessContext(old, DesktopAction.copy);
      expect(context.ownedDocument, isTrue);
      expect(
        _open(old, now, action: DesktopAction.copy),
        DesktopAccess.premiumRequired,
      );
      expect(
        _open(old, now, action: DesktopAction.save),
        DesktopAccess.premiumRequired,
      );
      expect(
        _open(old, now, action: DesktopAction.export),
        DesktopAccess.premiumRequired,
      );
    });
  });

  group('My Likes view model', () {
    final today = _like('t', DateTime(2026, 9, 12, 10));
    final yesterday = _like('y', DateTime(2026, 9, 11, 22));
    final old = _like('o', DateTime(2026, 8, 30, 8));

    test('locked likes are listed but excluded from the openable set', () {
      final data = buildMyLikesData(
        analyses: [today, yesterday, old],
        totalLiked: 3,
        query: const LikedAnalysesQuery(),
        subscription: _free,
        entitlement: _guest,
        now: now,
      );
      expect(data.visibleCount, 3);
      expect(data.lockedCount, 1);
      expect(data.openableAnalyses.map((a) => a.id), ['t', 'y']);
      expect(data.sections.map((s) => s.key), [
        '2026-09-12',
        '2026-09-11',
        '2026-08-30',
      ]);
      expect(data.sections.last.value.single.isLocked, isTrue);
    });

    test('an explicit sort collapses into one ordered section', () {
      final data = buildMyLikesData(
        analyses: [old, today],
        totalLiked: 2,
        query: const LikedAnalysesQuery(sort: LikedGamesSort.ratingHighest),
        subscription: _free,
        entitlement: _guest,
        now: now,
      );
      expect(data.sections.single.key, kMyLikesSortedSectionKey);
      expect(data.sections.single.value.map((e) => e.analysis.id), ['o', 't']);
    });

    test('tap-time openable set is recomputed against the clock', () {
      final atMidnight = DateTime(2026, 9, 18, 0, 1);
      expect(
        openableLikedAnalyses(
          [today, yesterday],
          subscription: _free,
          entitlement: _guest,
          now: now,
        ).map((a) => a.id),
        ['t', 'y'],
      );
      // Six days later yesterday's like has crossed the window.
      expect(
        openableLikedAnalyses(
          [today, yesterday],
          subscription: _free,
          entitlement: _guest,
          now: atMidnight,
        ).map((a) => a.id),
        ['t'],
      );
    });

    test('free export exports only the seven-day slice', () {
      final slice = likedGamesExportSlice(
        [today, old, yesterday],
        subscription: _free,
        entitlement: _guest,
        now: now,
      );
      expect(slice.accessible.map((a) => a.id), ['t', 'y']);
      expect(slice.locked, 1);
      expect(slice.isComplete, isFalse);

      final member = likedGamesExportSlice(
        [today, old],
        subscription: _premium,
        entitlement: _guest,
        now: now,
      );
      expect(member.accessible, hasLength(2));
      expect(member.isComplete, isTrue);
    });

    test('an unknown entitlement exports nothing it cannot prove', () {
      final slice = likedGamesExportSlice(
        [old],
        subscription: _unknown,
        entitlement: _guest,
        now: now,
      );
      expect(slice.accessible, isEmpty);
      expect(slice.locked, 0);
      expect(slice.undetermined, 1);
    });

    test('date headers use local calendar days, DST-safe', () {
      expect(formatLikedDateHeader('2026-09-12', now: now), 'Today');
      expect(formatLikedDateHeader('2026-09-11', now: now), 'Yesterday');
      expect(formatLikedDateHeader(kMyLikesUnknownDateKey), 'Unknown date');
      expect(
        formatLikedDateHeader('2026-03-08', now: DateTime(2026, 3, 9, 0, 30)),
        'Yesterday',
      );
    });

    test('an earlier year is named, this year is not', () {
      expect(formatLikedDateHeader('2026-09-04', now: now), 'Friday, Sep 4');
      expect(
        formatLikedDateHeader('2025-09-04', now: now),
        'Thursday, Sep 4, 2025',
      );
    });
  });

  group('Likes collection identity and quota semantics', () {
    test('identified by is_liked_games, never by name', () {
      LibraryFolder folder(Map<String, dynamic> extra) =>
          LibraryFolder.fromSupabase({
            'id': 'f',
            'user_id': 'u',
            'name': 'My Likes',
            'created_at': '2026-09-01T00:00:00Z',
            'updated_at': '2026-09-01T00:00:00Z',
            ...extra,
          });
      expect(folder({'is_liked_games': true}).isLikedGames, isTrue);
      expect(folder({}).isLikedGames, isFalse);
      expect(folder({'is_liked_games': true}).displayName, 'My Likes');
    });

    test('liking spends nothing; moving a like into a database is charged', () {
      const like = DesktopAccessContext(
        feature: DesktopFeature.likes,
        action: DesktopAction.create,
        origin: DesktopDiscoveryOrigin.likes,
      );
      expect(like.effectiveQuota, DesktopQuota.none);
      expect(
        like.copyWith(action: DesktopAction.tag).effectiveQuota,
        DesktopQuota.none,
      );
      expect(
        like.copyWith(action: DesktopAction.save).effectiveQuota,
        DesktopQuota.cloudSavedGames,
      );
    });

    test('the window check for a move spends no quota by itself', () {
      final context = likedGameAccessContext(
        _like('a', DateTime(2026, 9, 10)),
        DesktopAction.save,
      );
      // Capacity is checked separately by canSaveMoreGames before writing.
      expect(context.effectiveQuota, DesktopQuota.none);
    });
  });
}
