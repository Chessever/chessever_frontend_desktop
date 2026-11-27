import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_cloud_signals.dart';
import 'package:chessever/desktop/services/play/play_cloud_sync.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_help_rating.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_glicko.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/services/play/play_local_store.dart';

/// Per-time-control rating stats stored on `user_play_profiles`.
///
/// [rd], [volatility] and [lastPlayedAt] are the Glicko-2 state. Profiles
/// saved before Glicko-2 have none of them: RD is then derived from the
/// game count ([legacyRdForGames]) and volatility starts at the default.
@immutable
class PlayRatingStats {
  const PlayRatingStats({
    required this.rating,
    required this.peak,
    required this.gamesPlayed,
    required this.wins,
    required this.losses,
    required this.draws,
    this.rd,
    double? volatility,
    this.lastPlayedAt,
  }) : _volatility = volatility;

  final int rating;
  final int peak;
  final int gamesPlayed;
  final int wins;
  final int losses;
  final int draws;

  /// Stored rating deviation; null on legacy records.
  final double? rd;
  final double? _volatility;
  final DateTime? lastPlayedAt;

  static const PlayRatingStats initial = PlayRatingStats(
    rating: kPlayInitialRating,
    peak: kPlayInitialRating,
    gamesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
  );

  int get winRatePct =>
      gamesPlayed == 0 ? 0 : (100 * wins / gamesPlayed).round();

  /// Glicko-2 rating deviation, derived for legacy records.
  double get ratingDeviation => rd ?? legacyRdForGames(gamesPlayed);

  double get volatility => _volatility ?? kPlayInitialVolatility;

  /// Lichess shows these ratings with a "?".
  bool get isProvisional => ratingDeviation > kPlayProvisionalRd;

  /// "1234" or "1234?" when provisional.
  String get displayRating => isProvisional ? '$rating?' : '$rating';

  /// Legacy Elo update: counts the result without touching the Glicko
  /// state. Rated games go through [applyGlicko].
  PlayRatingStats applyResult({required int newRating, required double score}) {
    return PlayRatingStats(
      rating: newRating,
      peak: newRating > peak ? newRating : peak,
      gamesPlayed: gamesPlayed + 1,
      wins: wins + (score == 1 ? 1 : 0),
      losses: losses + (score == 0 ? 1 : 0),
      draws: draws + (score == 0.5 ? 1 : 0),
      rd: rd,
      volatility: _volatility,
      lastPlayedAt: lastPlayedAt,
    );
  }

  PlayRatingStats applyGlicko({
    required int newRating,
    required double rd,
    required double volatility,
    required double score,
    required DateTime at,
  }) {
    return PlayRatingStats(
      rating: newRating,
      peak: newRating > peak ? newRating : peak,
      gamesPlayed: gamesPlayed + 1,
      wins: wins + (score == 1 ? 1 : 0),
      losses: losses + (score == 0 ? 1 : 0),
      draws: draws + (score == 0.5 ? 1 : 0),
      rd: rd,
      volatility: volatility,
      lastPlayedAt: at,
    );
  }

  /// Same results, Glicko state taken from [other]. Used when the copy that
  /// wins a merge was saved without RD (a legacy row) and the other has it.
  PlayRatingStats withGlickoFrom(PlayRatingStats other) => PlayRatingStats(
    rating: rating,
    peak: peak,
    gamesPlayed: gamesPlayed,
    wins: wins,
    losses: losses,
    draws: draws,
    rd: other.rd,
    volatility: other._volatility,
    lastPlayedAt: other.lastPlayedAt,
  );

  Map<String, dynamic> toLocalJson() => {
    'rating': rating,
    'peak': peak,
    'gamesPlayed': gamesPlayed,
    'wins': wins,
    'losses': losses,
    'draws': draws,
    if (rd != null) 'rd': rd,
    if (_volatility != null) 'volatility': _volatility,
    if (lastPlayedAt != null)
      'lastPlayedAt': lastPlayedAt!.toUtc().toIso8601String(),
  };

  static PlayRatingStats fromLocalJson(Map<dynamic, dynamic> m) {
    return PlayRatingStats(
      rating: (m['rating'] as num?)?.toInt() ?? kPlayInitialRating,
      peak: (m['peak'] as num?)?.toInt() ?? kPlayInitialRating,
      gamesPlayed: (m['gamesPlayed'] as num?)?.toInt() ?? 0,
      wins: (m['wins'] as num?)?.toInt() ?? 0,
      losses: (m['losses'] as num?)?.toInt() ?? 0,
      draws: (m['draws'] as num?)?.toInt() ?? 0,
      rd: (m['rd'] as num?)?.toDouble(),
      volatility: (m['volatility'] as num?)?.toDouble(),
      lastPlayedAt:
          DateTime.tryParse(m['lastPlayedAt']?.toString() ?? '')?.toLocal(),
    );
  }
}

@immutable
class PlayUserProfile {
  const PlayUserProfile({
    required this.displayName,
    required this.avatarSeed,
    required this.ratings,
    required this.achievementPoints,
    this.lastGameAt,
    this.createdAt,
  });

  final String displayName;
  final String avatarSeed;
  final Map<RatedTimeControl, PlayRatingStats> ratings;
  final int achievementPoints;
  final DateTime? lastGameAt;
  final DateTime? createdAt;

  /// The ladder's stats. A ladder saved before Glicko-2 (or rebuilt from a
  /// server row) has no date of its own: the profile's last game stands in,
  /// so the first game after a long break still grows the RD for the idle
  /// days instead of rating a comeback as if no time had passed.
  PlayRatingStats statsFor(RatedTimeControl tc) {
    final stats = ratings[tc] ?? PlayRatingStats.initial;
    if (stats.lastPlayedAt != null ||
        stats.gamesPlayed == 0 ||
        lastGameAt == null) {
      return stats;
    }
    return PlayRatingStats(
      rating: stats.rating,
      peak: stats.peak,
      gamesPlayed: stats.gamesPlayed,
      wins: stats.wins,
      losses: stats.losses,
      draws: stats.draws,
      rd: stats.rd,
      volatility: stats.rd == null ? null : stats.volatility,
      lastPlayedAt: lastGameAt,
    );
  }

  int ratingFor(RatedTimeControl tc) => statsFor(tc).rating;

  int get gamesPlayedTotal =>
      ratings.values.fold(0, (sum, stats) => sum + stats.gamesPlayed);
  int get winsTotal => ratings.values.fold(0, (sum, stats) => sum + stats.wins);
  int get lossesTotal =>
      ratings.values.fold(0, (sum, stats) => sum + stats.losses);
  int get drawsTotal =>
      ratings.values.fold(0, (sum, stats) => sum + stats.draws);

  /// "Display" rating used by header/avatar banners. Picks the ladder
  /// the user has played the most games on, breaking ties by preferring
  /// rapid > blitz > classical > bullet (chess.com convention).
  int get headlineRating {
    final ordered = [
      RatedTimeControl.rapid,
      RatedTimeControl.blitz,
      RatedTimeControl.classical,
      RatedTimeControl.bullet,
    ];
    RatedTimeControl best = ordered.first;
    var bestGames = -1;
    for (final tc in ordered) {
      final games = statsFor(tc).gamesPlayed;
      if (games > bestGames) {
        bestGames = games;
        best = tc;
      }
    }
    return statsFor(best).rating;
  }

  RatedTimeControl get headlineTimeControl {
    final ordered = [
      RatedTimeControl.rapid,
      RatedTimeControl.blitz,
      RatedTimeControl.classical,
      RatedTimeControl.bullet,
    ];
    var best = ordered.first;
    var bestGames = -1;
    for (final tc in ordered) {
      final games = statsFor(tc).gamesPlayed;
      if (games > bestGames) {
        bestGames = games;
        best = tc;
      }
    }
    return best;
  }

  PlayUserProfile copyWith({
    String? displayName,
    String? avatarSeed,
    Map<RatedTimeControl, PlayRatingStats>? ratings,
    int? achievementPoints,
    DateTime? lastGameAt,
    DateTime? createdAt,
  }) {
    return PlayUserProfile(
      displayName: displayName ?? this.displayName,
      avatarSeed: avatarSeed ?? this.avatarSeed,
      ratings: ratings ?? this.ratings,
      achievementPoints: achievementPoints ?? this.achievementPoints,
      lastGameAt: lastGameAt ?? this.lastGameAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// This profile with the Glicko state of [local] on every ladder this
  /// copy saved without RD (a server row written before the `rd_*`
  /// columns existed). This device's Glicko state is a far better guess
  /// than one rebuilt from the game count.
  PlayUserProfile withGlickoStateFrom(PlayUserProfile local) {
    final next = Map<RatedTimeControl, PlayRatingStats>.from(ratings);
    for (final tc in RatedTimeControl.values) {
      final mine = ratings[tc] ?? PlayRatingStats.initial;
      final theirs = local.ratings[tc] ?? PlayRatingStats.initial;
      if (mine.rd != null || theirs.rd == null) continue;
      next[tc] = mine.withGlickoFrom(theirs);
    }
    return copyWith(ratings: next);
  }

  PlayUserProfile copyWithRating(RatedTimeControl tc, PlayRatingStats stats) {
    final next = Map<RatedTimeControl, PlayRatingStats>.from(ratings);
    next[tc] = stats;
    return copyWith(ratings: next);
  }

  Map<String, dynamic> toLocalJson() => {
    'displayName': displayName,
    'avatarSeed': avatarSeed,
    'achievementPoints': achievementPoints,
    'lastGameAt': lastGameAt?.toUtc().toIso8601String(),
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'ratings': {
      for (final entry in ratings.entries)
        entry.key.wire: entry.value.toLocalJson(),
    },
  };

  /// The `user_play_profiles` row. Every column the client owns, and never
  /// `rewards` or `settings` (written on their own, see
  /// `PlayProfileRepository`), so an upsert of this row cannot overwrite
  /// them. Values are kept inside the table's CHECKs, and the name and
  /// avatar are never empty (both columns are NOT NULL).
  Map<String, dynamic> toSupabaseJson(String userId) {
    int elo(int value) => value.clamp(kPlayMinRating, kPlayMaxRating);
    int count(int value) => value < 0 ? 0 : value;
    final name = displayName.trim();
    final seed = avatarSeed.trim();
    final row = <String, dynamic>{
      'user_id': userId,
      'display_name': name.isEmpty ? 'ChessEver Player' : name,
      'avatar_seed': seed.isEmpty ? 'local-player' : seed,
      'current_elo': elo(headlineRating),
      'games_played': count(gamesPlayedTotal),
      'wins': count(winsTotal),
      'losses': count(lossesTotal),
      'draws': count(drawsTotal),
      'achievement_points': count(achievementPoints),
      'last_game_at': lastGameAt?.toUtc().toIso8601String(),
    };
    for (final tc in RatedTimeControl.values) {
      // Raw ladder, not [statsFor]: a ladder's own date, never the
      // profile's last game standing in for it.
      final stats = ratings[tc] ?? PlayRatingStats.initial;
      final suffix = tc.wire;
      row['elo_$suffix'] = elo(stats.rating);
      row['peak_$suffix'] = elo(stats.peak);
      row['games_$suffix'] = count(stats.gamesPlayed);
      row['wins_$suffix'] = count(stats.wins);
      row['losses_$suffix'] = count(stats.losses);
      row['draws_$suffix'] = count(stats.draws);
      row['rd_$suffix'] = stats.rd;
      row['volatility_$suffix'] = stats.rd == null ? null : stats.volatility;
      row['last_played_$suffix'] =
          stats.lastPlayedAt?.toUtc().toIso8601String();
    }
    return row;
  }

  static PlayUserProfile fromJson(Map<String, dynamic> json) {
    int readInt(String camel, String snake, int fallback) {
      final value = json[camel] ?? json[snake];
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    String readString(String camel, String snake, String fallback) {
      final value = json[camel] ?? json[snake];
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? fallback : text;
    }

    final ratings = <RatedTimeControl, PlayRatingStats>{};

    final ratingsRaw = json['ratings'];
    if (ratingsRaw is Map) {
      for (final entry in ratingsRaw.entries) {
        final tc = ratedTimeControlFromString(entry.key.toString());
        if (tc == null) continue;
        final m = entry.value;
        if (m is! Map) continue;
        ratings[tc] = PlayRatingStats.fromLocalJson(m);
      }
    }

    double? readDouble(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '');
    }

    PlayRatingStats statsFromSnake(String suffix) => PlayRatingStats(
      rating: readInt('elo_$suffix', 'elo_$suffix', kPlayInitialRating),
      peak: readInt('peak_$suffix', 'peak_$suffix', kPlayInitialRating),
      gamesPlayed: readInt('games_$suffix', 'games_$suffix', 0),
      wins: readInt('wins_$suffix', 'wins_$suffix', 0),
      losses: readInt('losses_$suffix', 'losses_$suffix', 0),
      draws: readInt('draws_$suffix', 'draws_$suffix', 0),
      rd: readDouble('rd_$suffix'),
      volatility: readDouble('volatility_$suffix'),
      lastPlayedAt:
          DateTime.tryParse(
            json['last_played_$suffix']?.toString() ?? '',
          )?.toLocal(),
    );

    for (final tc in RatedTimeControl.values) {
      if (ratings.containsKey(tc)) continue;
      final stats = statsFromSnake(tc.wire);
      ratings[tc] = stats;
    }

    final lastRaw = json['lastGameAt'] ?? json['last_game_at'];
    final createdRaw = json['createdAt'] ?? json['created_at'];

    final hasAnyGames = ratings.values.any((stats) => stats.gamesPlayed > 0);
    if (!hasAnyGames) {
      final legacyCurrent = readInt('currentElo', 'current_elo', 0);
      final legacyGames = readInt('gamesPlayed', 'games_played', 0);
      if (legacyGames > 0 && legacyCurrent > 0) {
        ratings[RatedTimeControl.rapid] = PlayRatingStats(
          rating: legacyCurrent,
          peak: legacyCurrent,
          gamesPlayed: legacyGames,
          wins: readInt('wins', 'wins', 0),
          losses: readInt('losses', 'losses', 0),
          draws: readInt('draws', 'draws', 0),
        );
      }
    }

    return PlayUserProfile(
      displayName: readString(
        'displayName',
        'display_name',
        'ChessEver Player',
      ),
      avatarSeed: readString('avatarSeed', 'avatar_seed', 'local-player'),
      ratings: ratings,
      achievementPoints: readInt('achievementPoints', 'achievement_points', 0),
      lastGameAt: DateTime.tryParse(lastRaw?.toString() ?? '')?.toLocal(),
      createdAt: DateTime.tryParse(createdRaw?.toString() ?? '')?.toLocal(),
    );
  }

  static PlayUserProfile fallback([String? displayName]) => PlayUserProfile(
    displayName:
        (displayName?.trim().isNotEmpty == true)
            ? displayName!.trim()
            : 'ChessEver Player',
    avatarSeed: 'local-player',
    ratings: {
      for (final tc in RatedTimeControl.values) tc: PlayRatingStats.initial,
    },
    achievementPoints: 0,
  );
}

/// Single point on the date-vs-rating curve. One row per rated game.
@immutable
class PlayRatingPoint {
  const PlayRatingPoint({
    required this.playedAt,
    required this.rating,
    required this.delta,
    required this.opponentElo,
    required this.score,
    required this.kFactor,
    this.gameKey,
    this.rd,
    this.volatility,
  });

  final DateTime playedAt;
  final int rating;
  final int delta;
  final int? opponentElo;
  final double score;
  final int kFactor;
  final String? gameKey;

  /// Rating deviation after this game; null on points saved before
  /// Glicko-2.
  final double? rd;

  /// Glicko-2 volatility after this game; null on older points.
  final double? volatility;

  bool get isProvisional => (rd ?? 0) > kPlayProvisionalRd;

  PlayRatingPoint copyWith({double? rd, double? volatility}) => PlayRatingPoint(
    playedAt: playedAt,
    rating: rating,
    delta: delta,
    opponentElo: opponentElo,
    score: score,
    kFactor: kFactor,
    gameKey: gameKey,
    rd: rd ?? this.rd,
    volatility: volatility ?? this.volatility,
  );

  Map<String, dynamic> toLocalJson() => {
    'playedAt': playedAt.toUtc().toIso8601String(),
    'rating': rating,
    'delta': delta,
    'opponentElo': opponentElo,
    'score': score,
    'kFactor': kFactor,
    'gameKey': gameKey,
    if (rd != null) 'rd': rd,
    if (volatility != null) 'volatility': volatility,
  };

  /// The `user_play_rating_history` row, kept inside the table's CHECKs:
  /// rating 100..4000, opponent 1..4000 or null, score 0 / 0.5 / 1 and a
  /// positive `k_factor` (a Glicko-2 game whose rating did not move has an
  /// effective K of 0, which the column rejects).
  Map<String, dynamic> toSupabaseJson({
    required String userId,
    required RatedTimeControl tc,
  }) {
    final opponent = opponentElo;
    final cleanScore =
        score >= 0.75
            ? 1.0
            : score >= 0.25
            ? 0.5
            : 0.0;
    return {
      'user_id': userId,
      'time_control': tc.wire,
      'played_at': playedAt.toUtc().toIso8601String(),
      'rating': rating.clamp(kPlayMinRating, kPlayMaxRating),
      'delta': delta,
      'opponent_elo':
          opponent == null || opponent < 1 || opponent > kPlayMaxRating
              ? null
              : opponent,
      'score': cleanScore,
      'k_factor': kFactor < 1 ? 1 : kFactor,
      'game_key': gameKey,
      'rd': rd,
      'volatility': volatility,
    };
  }

  static PlayRatingPoint fromJson(Map<String, dynamic> json) {
    int? readIntOpt(String camel, String snake) {
      final v = json[camel] ?? json[snake];
      if (v == null) return null;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    double? readDouble(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '');
    }

    return PlayRatingPoint(
      playedAt:
          DateTime.tryParse(
            (json['playedAt'] ?? json['played_at'])?.toString() ?? '',
          )?.toLocal() ??
          DateTime.now(),
      rating: readIntOpt('rating', 'rating') ?? 1200,
      delta: readIntOpt('delta', 'delta') ?? 0,
      opponentElo: readIntOpt('opponentElo', 'opponent_elo'),
      score: readDouble('score') ?? 0,
      kFactor: readIntOpt('kFactor', 'k_factor') ?? 20,
      gameKey: (json['gameKey'] ?? json['game_key'])?.toString(),
      rd: readDouble('rd'),
      volatility: readDouble('volatility'),
    );
  }
}

/// What one sync pass did, for logs and tests.
class PlaySyncReport {
  int gamesUploaded = 0;
  int gamesPulled = 0;
  int pointsUploaded = 0;
  int pointsPulled = 0;
  bool profileUploaded = false;
  bool rewardsUploaded = false;
  bool rewardsPulled = false;
  int achievementRowsUploaded = 0;
  final List<String> failures = <String>[];

  /// The pass rewrote local documents the UI shows.
  bool get changedLocal =>
      gamesPulled > 0 || pointsPulled > 0 || rewardsPulled || _profileChanged;
  bool _profileChanged = false;

  @override
  String toString() =>
      'games +$gamesUploaded/-$gamesPulled, points +$pointsUploaded/'
      '-$pointsPulled, profile ${profileUploaded ? 'up' : 'no'}, rewards '
      '${rewardsUploaded ? 'up' : (rewardsPulled ? 'down' : 'no')}, badges '
      '+$achievementRowsUploaded, failures ${failures.length}';
}

/// How long saving a game waits for the server's ladders before it rates
/// the game from this device's.
const Duration kPlaySaveServerMergeTimeout = Duration(seconds: 3);

/// Play data on this device and on the server.
///
/// Every write lands on this device first ([PlayLocalStore]), then goes to
/// Supabase. What has not reached the server yet stays in an outbox
/// ([PlaySyncState]) and is uploaded on the next pass: after each game, on
/// launch with an account, on sign-in ([playCloudSyncProvider]). Each table
/// is written on its own, so one failing write never stops the others, and
/// every write is an idempotent upsert on the table's unique key.
class PlayProfileRepository {
  PlayProfileRepository({
    PlayGameAnalyzer analyzer = const PlayGameAnalyzer(),
    PlayLocalStore store = const PlayLocalStore(),
    PlayCloudGateway gateway = const SupabasePlayCloudGateway(),
    DateTime Function()? clock,
    Duration serverMergeTimeout = kPlaySaveServerMergeTimeout,
  }) : _analyzer = analyzer,
       _store = store,
       _gateway = gateway,
       _clock = clock ?? DateTime.now,
       _serverMergeTimeout = serverMergeTimeout;

  final PlayGameAnalyzer _analyzer;
  final PlayLocalStore _store;
  final PlayCloudGateway _gateway;
  final DateTime Function() _clock;
  final Duration _serverMergeTimeout;

  /// Most games kept on this device. The server keeps them all.
  static const int localGameCap = 1000;

  static const _profilePath = 'play_profile/profile.json';
  static const _gamesPath = 'play_profile/games.json';
  static String _historyPath(RatedTimeControl tc) =>
      'play_profile/history_${tc.wire}.json';

  Future<void> _serial = Future<void>.value();
  Future<void> _passChain = Future<void>.value();
  bool _fullPassDone = false;

  /// Runs [task] after every earlier sync pass (and every earlier task on
  /// the chain) finished, so it never sees a pass's half-done state.
  Future<T> _onPassChain<T>(Future<T> Function() task) {
    final result = _passChain.then((_) => task());
    _passChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Runs [task] after every earlier local read-modify-write finished.
  Future<T> _locked<T>(Future<T> Function() task) {
    final result = _serial.then((_) => task());
    _serial = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  PlayCloudUser? get _user {
    try {
      return _gateway.currentUser;
    } catch (_) {
      return null;
    }
  }

  String get currentDisplayName {
    final name = _user?.displayName?.trim() ?? '';
    return name.isEmpty ? 'ChessEver Player' : name;
  }

  // -------------------------------------------------------------------------
  // Public reads
  // -------------------------------------------------------------------------

  Future<PlayUserProfile> fetchProfile() async {
    final user = _user;
    if (user != null) {
      await _ensureOwnerSafe(user);
      try {
        final row = await _gateway.fetchProfileRow(user.id);
        final remote = row == null ? null : PlayUserProfile.fromJson(row);
        final state = await _readSyncState();
        return await _locked(() async {
          final local =
              await _readLocalProfile() ??
              PlayUserProfile.fallback(currentDisplayName);
          final merged = mergePlayProfiles(
            local: local,
            remote: remote,
            preferLocalIdentity: state.profileEdited || remote == null,
          );
          await _writeLocalProfileIfChanged(local, merged);
          return merged;
        });
      } catch (e) {
        playSyncLog('profile fetch failed: $e');
      }
    }
    return await _readLocalProfile() ??
        PlayUserProfile.fallback(currentDisplayName);
  }

  /// Saves a profile the player edited here (name, avatar) and uploads it.
  Future<void> saveProfile(PlayUserProfile profile) async {
    final user = _user;
    if (user != null) await _ensureOwnerSafe(user);
    await _locked(() async {
      await _writeLocalProfile(profile);
      final state = await _readSyncState();
      await _writeSyncState(state.withProfileEdit());
    });
    if (user == null) return;
    // On the pass chain: a pass that read the profile before this edit
    // finishes first, so its upload can never land after this one.
    await _onPassChain(() async {
      if (_user?.id != user.id) return;
      await _syncProfileAndRewards(user, PlaySyncReport());
    });
  }

  /// Newest games first: this device's games merged with the server's
  /// newest page. The full pull of every server game runs in [syncNow].
  Future<List<PlayGameRecord>> fetchRecentGames({int limit = 80}) async {
    final user = _user;
    if (user != null) {
      await _ensureOwnerSafe(user);
      try {
        final rows = await _gateway.fetchRecentGames(user.id, limit);
        final remote = rows.map(PlayGameRecord.fromJson).toList();
        await _mergeIntoLocalGames(remote);
      } catch (e) {
        playSyncLog('games fetch failed: $e');
      }
    }
    return _readLocalGames(limit: limit);
  }

  /// The date-vs-rating curve for one ladder, oldest first: this device's
  /// points merged with the server's.
  Future<List<PlayRatingPoint>> fetchRatingHistory(
    RatedTimeControl tc, {
    int limit = 500,
  }) async {
    final user = _user;
    if (user != null) {
      await _ensureOwnerSafe(user);
      try {
        final rows = await _gateway.fetchHistory(user.id, tc: tc);
        final remote = rows
            .map((row) => PlayRatingPoint.fromJson(row))
            .toList(growable: false);
        final merged = await _locked(() async {
          final local = await _readLocalHistory(tc);
          final next = mergePlayRatingPoints(local, remote);
          await _writeLocalHistory(tc, next);
          return next;
        });
        return merged.length > limit
            ? merged.sublist(merged.length - limit)
            : merged;
      } catch (e) {
        playSyncLog('rating history fetch failed: $e');
      }
    }
    final local = await _readLocalHistory(tc);
    return local.length > limit ? local.sublist(local.length - limit) : local;
  }

  // -------------------------------------------------------------------------
  // Settings (help style, help modules, ...): one jsonb on the profile row
  // -------------------------------------------------------------------------

  /// `{settings: Map, settings_updated_at: String?}` for the signed-in
  /// player, or null when signed out, offline or without a profile row.
  Future<Map<String, dynamic>?> fetchSettings() async {
    final user = _user;
    if (user == null) return null;
    try {
      final row = await _gateway.fetchProfileRow(user.id);
      if (row == null) return null;
      final raw = row['settings'];
      return {
        'settings':
            raw is Map
                ? Map<String, dynamic>.from(raw)
                : const <String, dynamic>{},
        'settings_updated_at': row['settings_updated_at']?.toString(),
      };
    } catch (e) {
      playSyncLog('settings fetch failed: $e');
      return null;
    }
  }

  /// Writes only `settings` and `settings_updated_at`. A missing profile
  /// row is first created from this device's profile, once the device's
  /// Play documents are this account's ([_ensureOwner]), so another
  /// account's ladders can never seed it. Runs on the pass chain. Signed
  /// out it does nothing. Throws when any step fails, so the caller keeps
  /// its own copy marked as not uploaded.
  Future<void> saveSettings(
    Map<String, dynamic> settings,
    DateTime updatedAt,
  ) async {
    final user = _user;
    if (user == null) return;
    await _onPassChain(() async {
      await _ensureOwner(user);
      if (_user?.id != user.id) {
        throw StateError('the account changed before the settings upload');
      }
      await _ensureProfileRow(user);
      await _gateway.upsertProfile({
        'user_id': user.id,
        'settings': settings,
        'settings_updated_at': updatedAt.toUtc().toIso8601String(),
      });
    });
  }

  /// A profile row with this device's ladders, created when missing, so a
  /// partial upsert never inserts a row with the table's default name and
  /// avatar. Throws when the row is not known to exist afterwards.
  Future<void> _ensureProfileRow(PlayCloudUser user) async {
    final row = await _gateway.fetchProfileRow(user.id);
    if (row != null) return;
    final report = PlaySyncReport();
    await _syncProfileAndRewards(user, report);
    if (!report.profileUploaded) {
      throw StateError('profile row missing: ${report.failures.join('; ')}');
    }
  }

  // -------------------------------------------------------------------------
  // Saving a game
  // -------------------------------------------------------------------------

  Future<PlayGameRecord> saveCompletedGame(
    PlayGameRecord record, {
    PlayAchievementsState? achievements,
  }) async {
    final user = _user;
    if (user != null) {
      await _ensureOwnerSafe(user);
      // Merges the server's ladders first, so this game is rated from the
      // newest rating any device has. Bounded: a stalled connection never
      // holds the game back from this device; it is rated from the local
      // ladder and the pass that follows merges the server's.
      try {
        await fetchProfile().timeout(_serverMergeTimeout);
      } on TimeoutException {
        playSyncLog('profile fetch slow; rating from this device');
      }
    }
    final enriched = await _locked(() async {
      final games = await _readLocalGames(limit: localGameCap);
      final existing = games.where(
        (game) => game.localGameKey == record.localGameKey,
      );
      final existingRecord = existing.isEmpty ? null : existing.first;
      final ratingAlreadyRecorded = existingRecord?.ratingAfter != null;
      var profile =
          await _readLocalProfile() ??
          PlayUserProfile.fallback(currentDisplayName);
      var enriched =
          ratingAlreadyRecorded
              ? record.copyWith(
                ratingBefore: existingRecord!.ratingBefore,
                ratingAfter: existingRecord.ratingAfter,
              )
              : record;
      final tc = playRatedTcForRecord(record);
      var state = await _readSyncState();
      final dirtyHistory = {...state.dirtyHistory};

      if (!ratingAlreadyRecorded && record.userScore != null && tc != null) {
        final rated = _rateGame(
          profile,
          record,
          tc,
          record.userScore!,
          at: record.playedAt,
        );
        enriched = rated.record;
        profile = rated.profile;
        await _appendLocalHistory(tc, rated.point);
        dirtyHistory.add(PlaySyncState.historyKey(tc, record.localGameKey));
      }
      final xp = achievements?.xp;
      if (xp != null && xp > profile.achievementPoints) {
        profile = profile.copyWith(achievementPoints: xp);
      }
      await _writeLocalProfile(profile);
      await _upsertLocalGames([enriched]);
      state = await _readSyncState();
      await _writeSyncState(
        state.copyWith(
          dirtyGames: {...state.dirtyGames, enriched.localGameKey},
          dirtyHistory: {...state.dirtyHistory, ...dirtyHistory},
          // Played before the guest hand-over was resolved: rated on the
          // guest's ladder, so it is rated again with the guest's games.
          adoptedGuestKeys:
              state.adoptedFromGuest
                  ? {...state.adoptedGuestKeys, enriched.localGameKey}
                  : null,
        ),
      );
      return enriched;
    });
    if (user != null) {
      // Not awaited: the board shows the result now, the upload follows.
      unawaited(syncNow(full: !_fullPassDone));
    }
    return enriched;
  }

  Future<void> saveTournamentSnapshot(TournamentSnapshot snapshot) async {
    final humanId = snapshot.humanParticipantId;
    if (humanId == null) return;
    final finished = snapshot.games.where(
      (g) =>
          g.status == TournamentGameStatus.finished &&
          g.movesUci.isNotEmpty &&
          (g.result ?? '*') != '*' &&
          (g.whiteId == humanId || g.blackId == humanId),
    );
    for (final game in finished) {
      final record = _analyzer.buildTournamentRecord(
        snapshot: snapshot,
        game: game,
      );
      await saveCompletedGame(record);
    }
  }

  // -------------------------------------------------------------------------
  // Sync
  // -------------------------------------------------------------------------

  /// One sync pass for the signed-in player. A quick pass ([full] false)
  /// uploads the outbox, the profile and the rewards. A full pass also
  /// compares every game and rating point with the server: uploads what the
  /// server lacks (a backfill of games played offline, signed out, as a
  /// guest or before the schema had a table for them) and pulls what this
  /// device lacks. Passes never overlap; one asked for during another
  /// waits for it and then runs.
  Future<PlaySyncReport> syncNow({bool full = true}) =>
      _onPassChain(() => _runPass(full: full));

  Future<PlaySyncReport> _runPass({required bool full}) async {
    final report = PlaySyncReport();
    final user = _user;
    if (user == null) return report;
    try {
      await _ensureOwner(user);
    } catch (e) {
      report.failures.add('owner: $e');
      playSyncLog('owner check failed: $e');
      return report;
    }
    // A guest's documents handed to this account are settled against the
    // account's server profile before anything of them is uploaded.
    if (!await _resolveGuestAdoption(user, report)) return report;
    if (full) {
      await _guard(
        report,
        'games reconcile',
        () => _reconcileGames(user, report),
      );
      await _guard(
        report,
        'history reconcile',
        () => _reconcileHistory(user, report),
      );
    }
    await _guard(report, 'games upload', () => _pushDirtyGames(user, report));
    await _guard(
      report,
      'history upload',
      () => _pushDirtyHistory(user, report),
    );
    await _syncProfileAndRewards(user, report);
    if (full && report.failures.isEmpty) _fullPassDone = true;
    playSyncLog('${full ? 'full' : 'quick'} pass: $report');
    return report;
  }

  Future<void> _guard(
    PlaySyncReport report,
    String step,
    Future<void> Function() task,
  ) async {
    try {
      await task();
    } catch (e) {
      report.failures.add('$step: $e');
      playSyncLog('$step failed: $e');
    }
  }

  /// Marks every local game the server lacks as owed, and pulls every
  /// server game this device lacks (newest first, up to [localGameCap]).
  Future<void> _reconcileGames(
    PlayCloudUser user,
    PlaySyncReport report,
  ) async {
    final index = await _gateway.fetchGameIndex(user.id);
    final serverKeys = <String>[
      for (final row in index)
        if (row['local_game_key'] != null) row['local_game_key'].toString(),
    ];
    final local = await _readLocalGames(limit: localGameCap);
    final localKeys = {for (final g in local) g.localGameKey};
    final serverSet = serverKeys.toSet();
    final missingOnServer = localKeys.difference(serverSet);
    if (missingOnServer.isNotEmpty) {
      await _locked(() async {
        final state = await _readSyncState();
        await _writeSyncState(
          state.copyWith(dirtyGames: {...state.dirtyGames, ...missingOnServer}),
        );
      });
    }
    final toPull = [
      for (final key in serverKeys.take(localGameCap))
        if (!localKeys.contains(key)) key,
    ];
    if (toPull.isEmpty) return;
    final rows = await _gateway.fetchGamesByKeys(user.id, toPull);
    final remote = rows.map(PlayGameRecord.fromJson).toList();
    report.gamesPulled += await _mergeIntoLocalGames(remote);
  }

  /// Same for rating points, on every ladder. A rated game with no point
  /// anywhere gets one rebuilt from its rating before and after.
  Future<void> _reconcileHistory(
    PlayCloudUser user,
    PlaySyncReport report,
  ) async {
    final rows = await _gateway.fetchHistory(user.id);
    final remoteByTc = <RatedTimeControl, List<PlayRatingPoint>>{};
    for (final row in rows) {
      final tc = ratedTimeControlFromString(row['time_control']?.toString());
      if (tc == null) continue;
      remoteByTc.putIfAbsent(tc, () => []).add(PlayRatingPoint.fromJson(row));
    }
    final games = await _readLocalGames(limit: localGameCap);
    await _locked(() async {
      final owed = <String>{};
      for (final tc in RatedTimeControl.values) {
        final remote = remoteByTc[tc] ?? const <PlayRatingPoint>[];
        final local = await _readLocalHistory(tc);
        var merged = mergePlayRatingPoints(local, remote);
        final rebuilt = synthesizePlayRatingPoints(tc, games, merged);
        if (rebuilt.isNotEmpty) {
          merged = mergePlayRatingPoints([...merged, ...rebuilt], const []);
        }
        final remoteKeys = {
          for (final p in remote)
            if (p.gameKey != null) p.gameKey!,
        };
        final localKeys = {
          for (final p in local)
            if (p.gameKey != null) p.gameKey!,
        };
        for (final p in merged) {
          final key = p.gameKey;
          if (key == null) continue;
          if (!remoteKeys.contains(key)) {
            owed.add(PlaySyncState.historyKey(tc, key));
          }
          if (!localKeys.contains(key)) report.pointsPulled++;
        }
        if (merged.length != local.length || rebuilt.isNotEmpty) {
          await _writeLocalHistory(tc, merged);
        }
      }
      if (owed.isNotEmpty) {
        final state = await _readSyncState();
        await _writeSyncState(
          state.copyWith(dirtyHistory: {...state.dirtyHistory, ...owed}),
        );
      }
    });
  }

  Future<void> _pushDirtyGames(
    PlayCloudUser user,
    PlaySyncReport report,
  ) async {
    final state = await _readSyncState();
    if (state.dirtyGames.isEmpty) return;
    final games = await _readLocalGames(limit: localGameCap);
    final byKey = {for (final g in games) g.localGameKey: g};
    final owed = state.dirtyGames.where(byKey.containsKey).toList();
    // Keys whose game left this device (past the cap) cannot be sent.
    final gone = state.dirtyGames.difference(owed.toSet());
    if (owed.isNotEmpty) {
      await _gateway.upsertGames([
        for (final key in owed) byKey[key]!.toSupabaseJson(user.id),
      ]);
      report.gamesUploaded += owed.length;
    }
    await _locked(() async {
      final now = await _readSyncState();
      await _writeSyncState(
        now.copyWith(dirtyGames: now.dirtyGames.difference({...owed, ...gone})),
      );
    });
  }

  Future<void> _pushDirtyHistory(
    PlayCloudUser user,
    PlaySyncReport report,
  ) async {
    final state = await _readSyncState();
    if (state.dirtyHistory.isEmpty) return;
    final rows = <Map<String, dynamic>>[];
    final sent = <String>{};
    for (final tc in RatedTimeControl.values) {
      final points = await _readLocalHistory(tc);
      for (final p in points) {
        final key = p.gameKey;
        if (key == null) continue;
        final owedKey = PlaySyncState.historyKey(tc, key);
        if (!state.dirtyHistory.contains(owedKey)) continue;
        rows.add(p.toSupabaseJson(userId: user.id, tc: tc));
        sent.add(owedKey);
      }
    }
    final gone = state.dirtyHistory.difference(sent);
    if (rows.isNotEmpty) {
      await _gateway.upsertHistory(rows);
      report.pointsUploaded += rows.length;
    }
    await _locked(() async {
      final now = await _readSyncState();
      await _writeSyncState(
        now.copyWith(
          dirtyHistory: now.dirtyHistory.difference({...sent, ...gone}),
        ),
      );
    });
  }

  /// Profile row (merged with the server's, then upserted, which creates
  /// it for a player who never had one), then rewards, then badge rows.
  /// Each step is logged and independent of the others.
  Future<void> _syncProfileAndRewards(
    PlayCloudUser user,
    PlaySyncReport report,
  ) async {
    if (!await _resolveGuestAdoption(user, report)) return;
    Map<String, dynamic>? row;
    try {
      row = await _gateway.fetchProfileRow(user.id);
    } catch (e) {
      report.failures.add('profile fetch: $e');
      playSyncLog('profile fetch failed: $e');
      return;
    }
    final remote = row == null ? null : PlayUserProfile.fromJson(row);
    PlayUserProfile? merged;
    // The profile edits this upload carries: read with the profile, so an
    // edit made while it is in flight stays pending.
    var editsInUpload = 0;
    try {
      final games = await _readLocalGames(limit: localGameCap);
      merged = await _locked(() async {
        final state = await _readSyncState();
        editsInUpload = state.profileEdits;
        final local =
            await _readLocalProfile() ??
            PlayUserProfile.fallback(user.displayName ?? currentDisplayName);
        var next = mergePlayProfiles(
          local: local,
          remote: remote,
          preferLocalIdentity: state.profileEdited || remote == null,
        );
        next = rebuildEmptyLaddersFromGames(next, games);
        if (await _writeLocalProfileIfChanged(local, next)) {
          report._profileChanged = true;
        }
        return next;
      });
    } catch (e) {
      report.failures.add('profile merge: $e');
      playSyncLog('profile merge failed: $e');
    }
    if (merged != null) {
      try {
        await _gateway.upsertProfile(merged.toSupabaseJson(user.id));
        report.profileUploaded = true;
        await _locked(() async {
          final state = await _readSyncState();
          if (state.profileEditsUploaded < editsInUpload) {
            await _writeSyncState(
              state.withProfileEditsUploaded(editsInUpload),
            );
          }
        });
      } catch (e) {
        report.failures.add('profile upload: $e');
        playSyncLog('profile upload failed: $e');
      }
    }
    // A partial upsert on a missing row would insert the table's default
    // name and a random avatar, which the next merge takes as the server's.
    final rowExists = row != null || report.profileUploaded;
    final effective = await _guardValue(
      report,
      'rewards',
      () => _syncRewards(user, row, report, rowExists: rowExists),
    );
    if (effective != null) {
      await _guard(
        report,
        'achievement rows',
        () => _syncAchievementRows(user, effective, report),
      );
    }
  }

  Future<T?> _guardValue<T>(
    PlaySyncReport report,
    String step,
    Future<T?> Function() task,
  ) async {
    try {
      return await task();
    } catch (e) {
      report.failures.add('$step: $e');
      playSyncLog('$step failed: $e');
      return null;
    }
  }

  /// Uploads this device's rewards state when it is newer, or takes the
  /// server's when that one is. Writes only `rewards` and
  /// `rewards_updated_at`. Returns the state that now stands.
  Future<PlayAchievementsState?> _syncRewards(
    PlayCloudUser user,
    Map<String, dynamic>? row,
    PlaySyncReport report, {
    required bool rowExists,
  }) async {
    final localText = await _store.read(kPlayAchievementsStatePath);
    final local = _decodeRewards(localText);
    final remoteRaw = row?['rewards'];
    final remote = remoteRaw is Map ? decodePlayRewardsState(remoteRaw) : null;
    final remoteAt = DateTime.tryParse(
      row?['rewards_updated_at']?.toString() ?? '',
    );
    switch (decidePlayRewardsWinner(
      local: local,
      remote: remote,
      remoteUpdatedAt: remoteAt,
    )) {
      case PlayRewardsWinner.none:
        return local ?? remote;
      case PlayRewardsWinner.local:
        if (!rowExists) {
          throw StateError('no profile row yet; the rewards wait for it');
        }
        // A state from before the sync carries no date: stamp it once so
        // the next comparison is by time.
        var stamped = local!;
        if (stamped.updatedAt == null) {
          stamped = stamped.copyWith(updatedAt: _clock());
          await _writeRewardsIfUnchanged(localText, stamped);
        }
        await _gateway.upsertProfile({
          'user_id': user.id,
          'rewards': encodePlayRewardsState(stamped),
          'rewards_updated_at': stamped.updatedAt!.toUtc().toIso8601String(),
        });
        report.rewardsUploaded = true;
        return stamped;
      case PlayRewardsWinner.remote:
        final next = remote!.copyWith(updatedAt: remoteAt ?? remote.updatedAt);
        if (await _writeRewardsIfUnchanged(localText, next)) {
          report.rewardsPulled = true;
          PlayCloudSignals.notifyLocalReplaced();
        }
        return next;
    }
  }

  PlayAchievementsState? _decodeRewards(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      final json = jsonDecode(text);
      return json is Map ? decodePlayRewardsState(json) : null;
    } catch (e) {
      playSyncLog('rewards decode failed: $e');
      return null;
    }
  }

  /// Writes [state] unless the file changed since it read [expected] (the
  /// achievements notifier saved a newer game meanwhile; the next pass
  /// compares again).
  Future<bool> _writeRewardsIfUnchanged(
    String? expected,
    PlayAchievementsState state,
  ) {
    return _locked(() async {
      final current = await _store.read(kPlayAchievementsStatePath);
      if ((current ?? '') != (expected ?? '')) return false;
      await _store.write(
        kPlayAchievementsStatePath,
        const JsonEncoder.withIndent(
          '  ',
        ).convert(encodePlayRewardsState(state)),
      );
      return true;
    });
  }

  /// One row per badge, `unlocked_at` the first unlock ever seen.
  Future<void> _syncAchievementRows(
    PlayCloudUser user,
    PlayAchievementsState state,
    PlaySyncReport report,
  ) async {
    final serverRows = await _gateway.fetchAchievementRows(user.id);
    final games = await _readLocalGames(limit: 1);
    final plan = buildPlayAchievementRows(
      userId: user.id,
      state: state,
      serverRows: serverRows,
      now: _clock(),
      latestGameKey: games.isEmpty ? null : games.first.localGameKey,
    );
    if (plan.rows.isNotEmpty) {
      await _gateway.upsertAchievementRows(plan.rows);
      report.achievementRowsUploaded += plan.rows.length;
    }
    if (plan.assignedEarnedAt.isEmpty) return;
    // Keep the first-unlock times locally too, without touching the
    // rewards date (it is the same state, only better documented).
    final text = await _store.read(kPlayAchievementsStatePath);
    final current = _decodeRewards(text);
    if (current == null) return;
    final earned = {...current.earnedAt};
    var changed = false;
    plan.assignedEarnedAt.forEach((id, at) {
      if (!earned.containsKey(id)) {
        earned[id] = at;
        changed = true;
      }
    });
    if (!changed) return;
    if (await _writeRewardsIfUnchanged(
      text,
      current.copyWith(earnedAt: earned),
    )) {
      PlayCloudSignals.notifyLocalReplaced();
    }
  }

  // -------------------------------------------------------------------------
  // Ownership of this device's Play documents
  // -------------------------------------------------------------------------

  /// Makes this device's Play documents the signed-in [user]'s: adopts
  /// unowned or guest documents (everything in them is uploaded by the next
  /// full pass), or, for another permanent account's documents, stashes
  /// them and restores [user]'s own stash.
  Future<void> _ensureOwner(PlayCloudUser user) {
    return _locked(() async {
      final state = await _readSyncState();
      switch (decidePlayOwnerAction(state, user.id)) {
        case PlayOwnerAction.keep:
          if (state.ownerIsAnonymous != user.isAnonymous) {
            await _writeSyncState(
              state.copyWith(ownerIsAnonymous: user.isAnonymous),
            );
          }
          return;
        case PlayOwnerAction.adopt:
          playSyncLog('adopting this device\'s Play data for the account');
          _fullPassDone = false;
          if (state.ownerUserId != null &&
              state.ownerIsAnonymous &&
              !user.isAnonymous) {
            await _adoptGuestDocuments(state, user.id);
            return;
          }
          await _writeSyncState(
            state.copyWith(
              ownerUserId: user.id,
              ownerIsAnonymous: user.isAnonymous,
            ),
          );
          return;
        case PlayOwnerAction.switchAccount:
          playSyncLog('switching Play data to another account');
          _fullPassDone = false;
          await _stashLocalData(state);
          final restored = await _restoreStash(user.id);
          await _writeSyncState(
            (restored?.state ?? PlaySyncState.empty).copyWith(
              ownerUserId: user.id,
              ownerIsAnonymous: user.isAnonymous,
            ),
          );
          PlayCloudSignals.notifyLocalReplaced(accountChanged: true);
          return;
      }
    });
  }

  Future<void> _ensureOwnerSafe(PlayCloudUser user) async {
    try {
      await _ensureOwner(user);
    } catch (e) {
      playSyncLog('owner check failed: $e');
    }
  }

  /// A guest signed in to [targetUserId]: the guest's documents on this
  /// device now belong to the account. Called by the guest merger.
  Future<void> adoptGuestPlayData({
    required String guestUserId,
    required String targetUserId,
  }) {
    return _locked(() async {
      final state = await _readSyncState();
      if (state.ownerUserId != guestUserId) return;
      _fullPassDone = false;
      await _adoptGuestDocuments(state, targetUserId);
    });
  }

  /// Hands the guest's documents to [targetUserId]. When the account left
  /// its own documents here (stashed when the guest took over), they come
  /// back with the guest's games and points merged in, and both outboxes
  /// are kept. The hand-over is flagged so the next pass settles it
  /// against the account's server profile ([_resolveGuestAdoption]) instead
  /// of letting the guest's ladders and rewards win by date. Caller holds
  /// the lock.
  Future<void> _adoptGuestDocuments(
    PlaySyncState guest,
    String targetUserId,
  ) async {
    final guestGames = await _readLocalGames(limit: localGameCap);
    final guestHistory = <RatedTimeControl, List<PlayRatingPoint>>{
      for (final tc in RatedTimeControl.values) tc: await _readLocalHistory(tc),
    };
    final guestKeys = {for (final g in guestGames) g.localGameKey};
    final stash = await _restoreStash(targetUserId);
    var next = guest;
    var overAccount = false;
    if (stash != null) {
      final own = stash.state ?? PlaySyncState.empty;
      overAccount = stash.paths.contains(_profilePath);
      if (guestGames.isNotEmpty) {
        final accountGames = await _readLocalGames(limit: localGameCap);
        await _writeLocalGames(
          mergePlayGameRecords(
            accountGames,
            guestGames,
            dirtyKeys: own.dirtyGames,
          ),
        );
      }
      for (final entry in guestHistory.entries) {
        if (entry.value.isEmpty) continue;
        final accountPoints = await _readLocalHistory(entry.key);
        await _writeLocalHistory(
          entry.key,
          mergePlayRatingPoints(accountPoints, entry.value),
        );
      }
      next = own.copyWith(
        dirtyGames: {...own.dirtyGames, ...guest.dirtyGames},
        dirtyHistory: {...own.dirtyHistory, ...guest.dirtyHistory},
        profileEdits: overAccount ? own.profileEdits : guest.profileEdits,
        profileEditsUploaded:
            overAccount ? own.profileEditsUploaded : guest.profileEditsUploaded,
      );
    }
    await _writeSyncState(
      next.copyWith(
        ownerUserId: targetUserId,
        ownerIsAnonymous: false,
        adoptedFromGuest: true,
        adoptedGuestKeys: {...guest.adoptedGuestKeys, ...guestKeys},
        adoptedOverAccountData: overAccount,
      ),
    );
    if (stash != null) {
      PlayCloudSignals.notifyLocalReplaced(accountChanged: true);
    }
  }

  /// Settles a guest hand-over against the account's server profile. When
  /// the account already has ladders (on the server, or in its restored
  /// documents), they stand and the guest's rated games are rated again on
  /// top of them; the account's rewards stand too. An account with nothing
  /// yet simply takes the guest's documents. Returns false when the server
  /// could not be read: nothing of the guest's may be uploaded until then.
  Future<bool> _resolveGuestAdoption(
    PlayCloudUser user,
    PlaySyncReport report,
  ) async {
    final pending = await _readSyncState();
    if (!pending.adoptedFromGuest || pending.ownerUserId != user.id) {
      return true;
    }
    try {
      final row = await _gateway.fetchProfileRow(user.id);
      final remote = row == null ? null : PlayUserProfile.fromJson(row);
      final remoteRewardsRaw = row?['rewards'];
      final remoteRewards =
          remoteRewardsRaw is Map
              ? decodePlayRewardsState(remoteRewardsRaw)
              : null;
      final remoteRewardsAt = DateTime.tryParse(
        row?['rewards_updated_at']?.toString() ?? '',
      );
      final remoteHasRewards =
          decidePlayRewardsWinner(
            local: null,
            remote: remoteRewards,
            remoteUpdatedAt: null,
          ) ==
          PlayRewardsWinner.remote;
      final replaced = await _locked(() async {
        final state = await _readSyncState();
        if (!state.adoptedFromGuest || state.ownerUserId != user.id) {
          return false;
        }
        var next = state.copyWith(
          adoptedFromGuest: false,
          adoptedGuestKeys: const <String>{},
          adoptedOverAccountData: false,
        );
        var changed = false;
        final local = await _readLocalProfile();
        PlayUserProfile? base;
        if (state.adoptedOverAccountData && local != null) {
          base = mergePlayProfiles(
            local: local,
            remote: remote,
            preferLocalIdentity: state.profileEdited || remote == null,
          );
        } else if (remote != null && remote.gamesPlayedTotal > 0) {
          base = remote;
          // The guest's name and avatar are not the account's.
          next = next.withProfileEditsUploaded(next.profileEdits);
        }
        if (base != null) {
          final rerated = await _rerateGames(base, state.adoptedGuestKeys);
          await _writeLocalProfile(rerated.profile);
          next = next.copyWith(
            dirtyGames: {...next.dirtyGames, ...rerated.games},
            dirtyHistory: {...next.dirtyHistory, ...rerated.history},
          );
          changed = true;
        }
        if (!state.adoptedOverAccountData && remoteHasRewards) {
          final accountRewards = remoteRewards!.copyWith(
            updatedAt: remoteRewardsAt ?? remoteRewards.updatedAt,
          );
          await _store.write(
            kPlayAchievementsStatePath,
            const JsonEncoder.withIndent(
              '  ',
            ).convert(encodePlayRewardsState(accountRewards)),
          );
          changed = true;
        }
        await _writeSyncState(next);
        return changed;
      });
      if (replaced) {
        report._profileChanged = true;
        PlayCloudSignals.notifyLocalReplaced();
      }
      return true;
    } catch (e) {
      report.failures.add('guest hand-over: $e');
      playSyncLog('guest hand-over failed: $e');
      return false;
    }
  }

  /// Rates the rated games among [keys] again, oldest first, on top of
  /// [base], and replaces their rating points. Returns the profile after
  /// them and the outbox keys they now owe. Caller holds the lock.
  Future<({PlayUserProfile profile, Set<String> games, Set<String> history})>
  _rerateGames(PlayUserProfile base, Set<String> keys) async {
    var profile = base;
    final dirtyGames = <String>{};
    final dirtyHistory = <String>{};
    if (keys.isEmpty) {
      return (profile: profile, games: dirtyGames, history: dirtyHistory);
    }
    final games = await _readLocalGames(limit: localGameCap);
    final mine =
        games.where((g) => keys.contains(g.localGameKey)).toList()
          ..sort((a, b) => a.playedAt.compareTo(b.playedAt));
    final updated = <PlayGameRecord>[];
    final points = <RatedTimeControl, List<PlayRatingPoint>>{};
    for (final game in mine) {
      dirtyGames.add(game.localGameKey);
      final tc = playRatedTcForRecord(game);
      final score = game.userScore;
      if (tc == null || score == null || game.ratingAfter == null) continue;
      // Never before the ladder's own last game, so the guest's games
      // count on it even when the account played later elsewhere.
      final last = profile.statsFor(tc).lastPlayedAt;
      final at =
          last != null && last.isAfter(game.playedAt) ? last : game.playedAt;
      final rated = _rateGame(profile, game, tc, score, at: at);
      profile = rated.profile;
      updated.add(rated.record);
      points.putIfAbsent(tc, () => []).add(rated.point);
      dirtyHistory.add(PlaySyncState.historyKey(tc, game.localGameKey));
    }
    if (updated.isNotEmpty) await _upsertLocalGames(updated);
    for (final tc in RatedTimeControl.values) {
      final existing = await _readLocalHistory(tc);
      final kept = [
        for (final p in existing)
          if (p.gameKey == null || !keys.contains(p.gameKey)) p,
      ];
      final added = points[tc] ?? const <PlayRatingPoint>[];
      if (kept.length == existing.length && added.isEmpty) continue;
      await _writeLocalHistory(tc, [...kept, ...added]);
    }
    return (profile: profile, games: dirtyGames, history: dirtyHistory);
  }

  /// Rates [record] on [tc] from [profile]'s ladder.
  ({PlayGameRecord record, PlayUserProfile profile, PlayRatingPoint point})
  _rateGame(
    PlayUserProfile profile,
    PlayGameRecord record,
    RatedTimeControl tc,
    double score, {
    required DateTime at,
  }) {
    final stats = profile.statsFor(tc);
    final opponent =
        record.opponentElo ??
        record.blackElo ??
        record.whiteElo ??
        stats.rating;
    final outcome = ratePlayGame(
      stats: stats,
      opponentRating: opponent,
      score: score,
      at: at,
      // Help the game used keeps only part of a gain.
      gainFactor: playHelpGainFactorFromMetadata(record.metadata),
    );
    var next = profile.copyWithRating(tc, outcome.statsAfter);
    final last = next.lastGameAt;
    if (last == null || record.playedAt.isAfter(last)) {
      next = next.copyWith(lastGameAt: record.playedAt);
    }
    return (
      record: record.copyWith(
        ratingBefore: outcome.ratingBefore,
        ratingAfter: outcome.ratingAfter,
      ),
      profile: next,
      point: PlayRatingPoint(
        playedAt: record.playedAt,
        rating: outcome.ratingAfter,
        delta: outcome.delta,
        opponentElo: opponent,
        score: score,
        kFactor: outcome.effectiveK,
        gameKey: record.localGameKey,
        rd: outcome.rdAfter,
        volatility: outcome.volatilityAfter,
      ),
    );
  }

  List<String> get _documentPaths => [
    _profilePath,
    _gamesPath,
    for (final tc in RatedTimeControl.values) _historyPath(tc),
    kPlayAchievementsStatePath,
  ];

  Future<void> _stashLocalData(PlaySyncState state) async {
    final owner = state.ownerUserId;
    if (owner == null) return;
    final documents = <String, String>{};
    for (final path in _documentPaths) {
      final text = await _store.read(path);
      if (text != null && text.trim().isNotEmpty) documents[path] = text;
    }
    await _store.write(
      playSyncStashPath(owner),
      jsonEncode({'state': state.toJson(), 'documents': documents}),
    );
    for (final path in _documentPaths) {
      if (documents.containsKey(path)) await _store.write(path, '');
    }
  }

  /// Writes [userId]'s stashed documents back. Null when there is no
  /// stash; otherwise the stashed outbox state and the restored paths.
  Future<({PlaySyncState? state, Set<String> paths})?> _restoreStash(
    String userId,
  ) async {
    final path = playSyncStashPath(userId);
    final text = await _store.read(path);
    if (text == null || text.trim().isEmpty) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final documents = (json['documents'] as Map?) ?? const {};
      final paths = <String>{};
      for (final entry in documents.entries) {
        await _store.write(entry.key.toString(), entry.value.toString());
        paths.add(entry.key.toString());
      }
      await _store.write(path, '');
      final stateJson = json['state'];
      return (
        state: stateJson is Map ? PlaySyncState.fromJson(stateJson) : null,
        paths: paths,
      );
    } catch (e) {
      playSyncLog('stash restore failed: $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Local documents
  // -------------------------------------------------------------------------

  Future<PlaySyncState> _readSyncState() async {
    try {
      final text = await _store.read(kPlaySyncStatePath);
      if (text == null || text.trim().isEmpty) return PlaySyncState.empty;
      final json = jsonDecode(text);
      return json is Map ? PlaySyncState.fromJson(json) : PlaySyncState.empty;
    } catch (e) {
      playSyncLog('sync state read failed: $e');
      return PlaySyncState.empty;
    }
  }

  Future<void> _writeSyncState(PlaySyncState state) =>
      _store.write(kPlaySyncStatePath, jsonEncode(state.toJson()));

  Future<PlayUserProfile?> _readLocalProfile() async {
    try {
      final text = await _store.read(_profilePath);
      if (text == null || text.trim().isEmpty) return null;
      final json = jsonDecode(text) as Map<String, dynamic>;
      return PlayUserProfile.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLocalProfile(PlayUserProfile profile) async {
    await _store.write(
      _profilePath,
      const JsonEncoder.withIndent('  ').convert(profile.toLocalJson()),
    );
  }

  Future<bool> _writeLocalProfileIfChanged(
    PlayUserProfile before,
    PlayUserProfile after,
  ) async {
    if (jsonEncode(before.toLocalJson()) == jsonEncode(after.toLocalJson())) {
      return false;
    }
    await _writeLocalProfile(after);
    return true;
  }

  Future<List<PlayGameRecord>> _readLocalGames({required int limit}) async {
    try {
      final text = await _store.read(_gamesPath);
      if (text == null || text.trim().isEmpty) return const <PlayGameRecord>[];
      final json = jsonDecode(text) as List<dynamic>;
      final games =
          json
              .whereType<Map>()
              .map(
                (row) => PlayGameRecord.fromJson(row.cast<String, dynamic>()),
              )
              .toList();
      games.sort((a, b) => b.playedAt.compareTo(a.playedAt));
      return games.take(limit).toList(growable: false);
    } catch (e) {
      playSyncLog('local game read failed: $e');
      return const <PlayGameRecord>[];
    }
  }

  Future<void> _writeLocalGames(List<PlayGameRecord> games) async {
    final sorted = [...games]..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    await _store.write(
      _gamesPath,
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sorted.take(localGameCap).map((g) => g.toLocalJson()).toList()),
    );
  }

  /// Caller holds the lock.
  Future<void> _upsertLocalGames(List<PlayGameRecord> records) async {
    final games = await _readLocalGames(limit: localGameCap);
    final byKey = {for (final game in games) game.localGameKey: game};
    for (final record in records) {
      byKey[record.localGameKey] = record;
    }
    await _writeLocalGames(byKey.values.toList());
  }

  /// Merges server games into this device's list in one write. Returns how
  /// many games this device did not have.
  Future<int> _mergeIntoLocalGames(List<PlayGameRecord> remote) {
    if (remote.isEmpty) return Future.value(0);
    return _locked(() async {
      final local = await _readLocalGames(limit: localGameCap);
      final state = await _readSyncState();
      final localKeys = {for (final g in local) g.localGameKey};
      final merged = mergePlayGameRecords(
        local,
        remote,
        dirtyKeys: state.dirtyGames,
      );
      final added = remote.where((g) => !localKeys.contains(g.localGameKey));
      final changed =
          added.isNotEmpty ||
          jsonEncode(local.map((g) => g.toLocalJson()).toList()) !=
              jsonEncode(merged.map((g) => g.toLocalJson()).toList());
      if (changed) await _writeLocalGames(merged);
      return added.length;
    });
  }

  Future<List<PlayRatingPoint>> _readLocalHistory(RatedTimeControl tc) async {
    try {
      final text = await _store.read(_historyPath(tc));
      if (text == null || text.trim().isEmpty) return const <PlayRatingPoint>[];
      final raw = jsonDecode(text) as List<dynamic>;
      final points =
          raw
              .whereType<Map>()
              .map(
                (row) => PlayRatingPoint.fromJson(row.cast<String, dynamic>()),
              )
              .toList();
      points.sort((a, b) => a.playedAt.compareTo(b.playedAt));
      return points;
    } catch (e) {
      playSyncLog('rating history local read failed: $e');
      return const <PlayRatingPoint>[];
    }
  }

  Future<void> _writeLocalHistory(
    RatedTimeControl tc,
    List<PlayRatingPoint> points,
  ) async {
    final sorted = [...points]
      ..sort((a, b) => a.playedAt.compareTo(b.playedAt));
    await _store.write(
      _historyPath(tc),
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sorted.map((p) => p.toLocalJson()).toList()),
    );
  }

  /// Caller holds the lock.
  Future<void> _appendLocalHistory(
    RatedTimeControl tc,
    PlayRatingPoint point,
  ) async {
    final existing = await _readLocalHistory(tc);
    final key = point.gameKey;
    final next = [
      for (final p in existing)
        if (key == null || p.gameKey != key) p,
      point,
    ];
    await _writeLocalHistory(tc, next);
  }
}

bool _shouldPreferLocalProfile(PlayUserProfile local, PlayUserProfile remote) {
  if (local.gamesPlayedTotal != remote.gamesPlayedTotal) {
    return local.gamesPlayedTotal > remote.gamesPlayedTotal;
  }
  final localLast = local.lastGameAt;
  final remoteLast = remote.lastGameAt;
  if (localLast != null && remoteLast == null) return true;
  if (localLast != null && remoteLast != null) {
    return localLast.isAfter(remoteLast);
  }
  if (local.achievementPoints != remote.achievementPoints) {
    return local.achievementPoints > remote.achievementPoints;
  }
  return false;
}

@visibleForTesting
bool debugShouldPreferLocalPlayProfile(
  PlayUserProfile local,
  PlayUserProfile remote,
) {
  return _shouldPreferLocalProfile(local, remote);
}

final playProfileRepositoryProvider = Provider<PlayProfileRepository>(
  (ref) => PlayProfileRepository(),
);

final playUserProfileProvider = FutureProvider.autoDispose<PlayUserProfile>((
  ref,
) async {
  return ref.watch(playProfileRepositoryProvider).fetchProfile();
});

final playRecentGamesProvider =
    FutureProvider.autoDispose<List<PlayGameRecord>>((ref) async {
      return ref.watch(playProfileRepositoryProvider).fetchRecentGames();
    });

/// Rating history (date-vs-elo points) for one rated ladder.
final playRatingHistoryProvider = FutureProvider.autoDispose
    .family<List<PlayRatingPoint>, RatedTimeControl>((ref, tc) async {
      return ref.watch(playProfileRepositoryProvider).fetchRatingHistory(tc);
    });
