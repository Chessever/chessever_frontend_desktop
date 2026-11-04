import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Community Likes: the games ChessEver users liked most in a calendar day,
/// week, month or year, and the players in those games.
///
/// Ported from the phone's Discovery › Likes
/// (`chessever-frontend/lib/screens/for_you/discovery/models/discovery_models.dart`)
/// so both clients read the same ranking RPC the same way. Keep the two in
/// step: the window, the qualifying floor and the tie order are part of the
/// ranking's meaning, not presentation.

/// The ranking periods. Every period is browsed by everyone; opening a game
/// outside the current day is Premium.
enum CommunityLikesPeriod { today, week, month, year }

extension CommunityLikesPeriodX on CommunityLikesPeriod {
  String get label => switch (this) {
    CommunityLikesPeriod.today => 'Today',
    CommunityLikesPeriod.week => 'Week',
    CommunityLikesPeriod.month => 'Month',
    CommunityLikesPeriod.year => 'Year',
  };

  /// "day", "week"... for the previous / next controls.
  String get unit => switch (this) {
    CommunityLikesPeriod.today => 'day',
    CommunityLikesPeriod.week => 'week',
    CommunityLikesPeriod.month => 'month',
    CommunityLikesPeriod.year => 'year',
  };
}

/// The first day there are likes to rank (the liked-games folder shipped on
/// 30 May 2026). Date navigation stops at the period holding it.
final DateTime kCommunityLikesFirstDay = DateTime(2026, 5, 30);

/// Games per ranking page. One extra aggregate row detects the next page.
const int kCommunityLikesPageSize = 12;

/// The local calendar day [t] falls on.
DateTime communityLikesDay(DateTime t) => DateTime(t.year, t.month, t.day);

/// Local start of the calendar [period] holding [day]: its midnight, the
/// Monday of its week, the 1st of its month, 1 January.
DateTime communityLikesPeriodStart(CommunityLikesPeriod period, DateTime day) {
  return switch (period) {
    CommunityLikesPeriod.today => DateTime(day.year, day.month, day.day),
    CommunityLikesPeriod.week => DateTime(
      day.year,
      day.month,
      day.day - (day.weekday - DateTime.monday),
    ),
    CommunityLikesPeriod.month => DateTime(day.year, day.month),
    CommunityLikesPeriod.year => DateTime(day.year),
  };
}

/// Start of the period [steps] periods after the one starting at [start].
/// Calendar arithmetic, so a day across a DST change is still one day.
DateTime communityLikesShift(
  CommunityLikesPeriod period,
  DateTime start,
  int steps,
) {
  return switch (period) {
    CommunityLikesPeriod.today => DateTime(
      start.year,
      start.month,
      start.day + steps,
    ),
    CommunityLikesPeriod.week => DateTime(
      start.year,
      start.month,
      start.day + 7 * steps,
    ),
    CommunityLikesPeriod.month => DateTime(start.year, start.month + steps),
    CommunityLikesPeriod.year => DateTime(start.year + steps),
  };
}

/// One ranking to read: a period and which one of it. Equal queries read the
/// same window, so this is the key the ranking read is cached under.
@immutable
class CommunityLikesQuery {
  CommunityLikesQuery(this.period, DateTime day)
    : start = communityLikesPeriodStart(period, day);

  final CommunityLikesPeriod period;

  /// Local midnight the period starts on.
  final DateTime start;

  /// Local midnight the next period starts on (exclusive end).
  DateTime get end => communityLikesShift(period, start, 1);

  /// The `[from, to)` window the ranking RPC counts likes in. Always a
  /// calendar period, never a rolling one.
  ({DateTime from, DateTime to}) get window => (from: start, to: end);

  /// Whether this is the period holding [now].
  bool isCurrent(DateTime now) =>
      start == communityLikesPeriodStart(period, now);

  /// Only the current day's ranking opens freely.
  bool isFree(DateTime now) =>
      period == CommunityLikesPeriod.today && isCurrent(now);

  /// The period before this one, or null once it would hold no day on or
  /// after [kCommunityLikesFirstDay].
  CommunityLikesQuery? get previous {
    if (!start.isAfter(communityLikesDay(kCommunityLikesFirstDay))) {
      return null;
    }
    return CommunityLikesQuery(period, communityLikesShift(period, start, -1));
  }

  /// The period after this one, or null on the current one: the future has
  /// no ranking.
  CommunityLikesQuery? next(DateTime now) {
    if (!start.isBefore(communityLikesPeriodStart(period, now))) return null;
    return CommunityLikesQuery(period, end);
  }

  /// What the date control reads: "Today", "Yesterday", "Wed, Sep 23",
  /// "Sep 21–27", "Sep 28 – Oct 4", "September", "2026". The year is added
  /// only when the period is not in [now]'s year.
  String label(DateTime now) {
    final thisYear = start.year == now.year;
    switch (period) {
      case CommunityLikesPeriod.today:
        final today = communityLikesDay(now);
        if (start == today) return 'Today';
        if (start == DateTime(today.year, today.month, today.day - 1)) {
          return 'Yesterday';
        }
        return thisYear
            ? DateFormat('EEE, MMM d').format(start)
            : DateFormat('EEE, MMM d, y').format(start);
      case CommunityLikesPeriod.week:
        final last = DateTime(start.year, start.month, start.day + 6);
        if (last.year != start.year) {
          return '${DateFormat.yMMMd().format(start)} – '
              '${DateFormat.yMMMd().format(last)}';
        }
        final first = DateFormat.MMMd().format(start);
        final range =
            start.month == last.month
                ? '$first–${last.day}'
                : '$first – ${DateFormat.MMMd().format(last)}';
        return thisYear ? range : '$range, ${last.year}';
      case CommunityLikesPeriod.month:
        return thisYear
            ? DateFormat.MMMM().format(start)
            : DateFormat.yMMMM().format(start);
      case CommunityLikesPeriod.year:
        return '${start.year}';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CommunityLikesQuery &&
      other.period == period &&
      other.start == start;

  @override
  int get hashCode => Object.hash(period, start);

  @override
  String toString() => 'CommunityLikesQuery(${period.name}, $start)';
}

/// One ranked row as the backend returns it.
@immutable
class CommunityLikesCount {
  const CommunityLikesCount({required this.gameId, required this.likes});

  final String gameId;
  final int likes;

  @override
  bool operator ==(Object other) =>
      other is CommunityLikesCount &&
      other.gameId == gameId &&
      other.likes == likes;

  @override
  int get hashCode => Object.hash(gameId, likes);
}

/// Parses ranking rows. A game needs at least two likes in the window to
/// qualify; rows without an id or a valid count are dropped, and a repeated
/// id keeps its first count. The order (likes desc, id asc) is re-applied so
/// the ranking stays deterministic whatever the transport does to it.
List<CommunityLikesCount> parseCommunityLikesRows(Object? data) {
  if (data is! List) return const [];
  final seen = <String>{};
  final out = <CommunityLikesCount>[];
  for (final raw in data) {
    if (raw is! Map) continue;
    final id = raw['source_game_id']?.toString().trim() ?? '';
    final likes = _asInt(raw['like_count']);
    if (id.isEmpty || likes == null || likes < 2) continue;
    if (!seen.add(id)) continue;
    out.add(CommunityLikesCount(gameId: id, likes: likes));
  }
  out.sort((a, b) {
    final byLikes = b.likes.compareTo(a.likes);
    return byLikes != 0 ? byLikes : a.gameId.compareTo(b.gameId);
  });
  return out;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.isFinite ? v.toInt() : null;
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// One ranked game ready to draw.
@immutable
class CommunityLikesEntry {
  const CommunityLikesEntry({
    required this.rank,
    required this.likes,
    required this.game,
  });

  /// 1-based position in the backend ranking. A game that could not be
  /// resolved keeps its place empty instead of shifting everyone up, so the
  /// number beside a game is always its true rank.
  final int rank;
  final int likes;
  final GamesTourModel game;
}

/// Joins the backend ranking with the games that resolved. Unresolved ids are
/// skipped, never replaced by a placeholder.
List<CommunityLikesEntry> assembleCommunityLikesEntries({
  required List<CommunityLikesCount> counts,
  required Map<String, GamesTourModel> gamesById,
  int rankOffset = 0,
}) {
  return [
    for (var i = 0; i < counts.length; i++)
      if (gamesById[counts[i].gameId] case final game?)
        CommunityLikesEntry(
          rank: rankOffset + i + 1,
          likes: counts[i].likes,
          game: game,
        ),
  ];
}

/// One row of the Players view.
@immutable
class CommunityLikesPlayer {
  const CommunityLikesPlayer({
    required this.rank,
    required this.player,
    required this.games,
    required this.likes,
  });

  final int rank;
  final PlayerCard player;

  /// How many of the ranked games are theirs.
  final int games;

  /// The likes those games drew (both sides of a game get its likes).
  final int likes;

  /// The identity [entryHasPlayer] matches on.
  String get key => communityLikesPlayerKey(player);
}

/// A player is one FIDE id, else one Gamebase id, else one name, so the same
/// person under two event spellings folds together when an id is known.
String communityLikesPlayerKey(PlayerCard p) {
  final fide = p.fideId;
  if (fide != null && fide > 0) return 'fide:$fide';
  final gamebase = p.gamebasePlayerId?.trim() ?? '';
  if (gamebase.isNotEmpty) return 'gamebase:$gamebase';
  return 'name:${p.name.trim().toLowerCase()}';
}

/// Whether [entry]'s game has [player] on either side.
bool communityLikesEntryHasPlayer(
  CommunityLikesEntry entry,
  CommunityLikesPlayer player,
) {
  final key = player.key;
  return communityLikesPlayerKey(entry.game.whitePlayer) == key ||
      communityLikesPlayerKey(entry.game.blackPlayer) == key;
}

/// The players with games in [entries], ranked by likes desc, then games
/// desc, then name, so ties never swap. A side with no usable name is left
/// out rather than shown as "?".
List<CommunityLikesPlayer> aggregateCommunityLikesPlayers(
  List<CommunityLikesEntry> entries,
) {
  final byKey = <String, ({PlayerCard player, int games, int likes})>{};
  for (final entry in entries) {
    final seenInGame = <String>{};
    for (final side in [entry.game.whitePlayer, entry.game.blackPlayer]) {
      final name = side.name.trim();
      if (name.isEmpty || name == '?') continue;
      final key = communityLikesPlayerKey(side);
      if (!seenInGame.add(key)) continue;
      final prior = byKey[key];
      if (prior == null) {
        byKey[key] = (player: side, games: 1, likes: entry.likes);
        continue;
      }
      byKey[key] = (
        player: _richer(prior.player, side),
        games: prior.games + 1,
        likes: prior.likes + entry.likes,
      );
    }
  }
  final rows =
      byKey.values.toList()..sort((a, b) {
        final byLikes = b.likes.compareTo(a.likes);
        if (byLikes != 0) return byLikes;
        final byGames = b.games.compareTo(a.games);
        if (byGames != 0) return byGames;
        return a.player.name.toLowerCase().compareTo(
          b.player.name.toLowerCase(),
        );
      });
  return [
    for (var i = 0; i < rows.length; i++)
      CommunityLikesPlayer(
        rank: i + 1,
        player: rows[i].player,
        games: rows[i].games,
        likes: rows[i].likes,
      ),
  ];
}

/// Keeps the richest card seen: a rating, title or flag another event carried
/// fills in what this one lacked.
PlayerCard _richer(PlayerCard a, PlayerCard b) {
  return a.copyWith(
    title: a.title.trim().isEmpty ? b.title : null,
    rating: b.rating > a.rating ? b.rating : null,
    countryCode: a.countryCode.trim().isEmpty ? b.countryCode : null,
    federation: a.federation.trim().isEmpty ? b.federation : null,
    fideId: a.fideId ?? b.fideId,
    gamebasePlayerId: a.gamebasePlayerId ?? b.gamebasePlayerId,
  );
}

enum CommunityLikesStatus {
  /// The ranking answered (possibly with no games yet).
  ranked,

  /// The ranking function is not deployed on this backend yet.
  notLive,

  /// The backend refused a Premium window for this account.
  premiumRequired,
}

typedef CommunityLikesCursor = ({int likes, String gameId, int rank});

@immutable
class CommunityLikesResult {
  const CommunityLikesResult.ranked(this.entries, {this.nextCursor})
    : status = CommunityLikesStatus.ranked;

  const CommunityLikesResult.notLive()
    : entries = const <CommunityLikesEntry>[],
      nextCursor = null,
      status = CommunityLikesStatus.notLive;

  const CommunityLikesResult.premiumRequired()
    : entries = const <CommunityLikesEntry>[],
      nextCursor = null,
      status = CommunityLikesStatus.premiumRequired;

  final CommunityLikesCursor? nextCursor;
  final CommunityLikesStatus status;
  final List<CommunityLikesEntry> entries;
}

/// Why the ranking RPC failed, as far as the pane needs to know.
enum CommunityLikesFailure { missingFunction, premiumRequired, other }

/// PostgREST answers `PGRST202` when the function is not in its schema cache;
/// Postgres answers `42883` (undefined_function) when called another way.
CommunityLikesFailure classifyCommunityLikesError(Object error) {
  if (error is PostgrestException) {
    final code = error.code?.trim();
    if (code == 'PGRST202' || code == '42883') {
      return CommunityLikesFailure.missingFunction;
    }
    if (error.message.contains('premium_required')) {
      return CommunityLikesFailure.premiumRequired;
    }
  }
  return CommunityLikesFailure.other;
}

/// "1 like", "2 likes", "1.2K likes".
String communityLikesLabel(int likes) =>
    likes == 1 ? '1 like' : '${compactLikeCount(likes)} likes';

/// "999", "1.2K", "12K", "1.5M".
String compactLikeCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final k = n / 1000;
    return k < 10 ? '${_oneDecimal(k)}K' : '${k.floor()}K';
  }
  final m = n / 1000000;
  return m < 10 ? '${_oneDecimal(m)}M' : '${m.floor()}M';
}

String _oneDecimal(double v) {
  final floored = (v * 10).floor() / 10;
  return floored == floored.roundToDouble()
      ? '${floored.toInt()}'
      : floored.toStringAsFixed(1);
}
