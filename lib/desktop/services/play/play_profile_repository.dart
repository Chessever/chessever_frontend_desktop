import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';

/// Per-time-control rating stats stored on `user_play_profiles`.
@immutable
class PlayRatingStats {
  const PlayRatingStats({
    required this.rating,
    required this.peak,
    required this.gamesPlayed,
    required this.wins,
    required this.losses,
    required this.draws,
  });

  final int rating;
  final int peak;
  final int gamesPlayed;
  final int wins;
  final int losses;
  final int draws;

  static const PlayRatingStats initial = PlayRatingStats(
    rating: 1200,
    peak: 1200,
    gamesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
  );

  int get winRatePct =>
      gamesPlayed == 0 ? 0 : (100 * wins / gamesPlayed).round();

  PlayRatingStats applyResult({required int newRating, required double score}) {
    return PlayRatingStats(
      rating: newRating,
      peak: newRating > peak ? newRating : peak,
      gamesPlayed: gamesPlayed + 1,
      wins: wins + (score == 1 ? 1 : 0),
      losses: losses + (score == 0 ? 1 : 0),
      draws: draws + (score == 0.5 ? 1 : 0),
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

  PlayRatingStats statsFor(RatedTimeControl tc) =>
      ratings[tc] ?? PlayRatingStats.initial;

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
        entry.key.wire: {
          'rating': entry.value.rating,
          'peak': entry.value.peak,
          'gamesPlayed': entry.value.gamesPlayed,
          'wins': entry.value.wins,
          'losses': entry.value.losses,
          'draws': entry.value.draws,
        },
    },
  };

  Map<String, dynamic> toSupabaseJson(String userId) {
    final classical = statsFor(RatedTimeControl.classical);
    final rapid = statsFor(RatedTimeControl.rapid);
    final blitz = statsFor(RatedTimeControl.blitz);
    final bullet = statsFor(RatedTimeControl.bullet);
    return {
      'user_id': userId,
      'display_name': displayName,
      'avatar_seed': avatarSeed,
      'current_elo': headlineRating,
      'games_played': gamesPlayedTotal,
      'wins': winsTotal,
      'losses': lossesTotal,
      'draws': drawsTotal,
      'achievement_points': achievementPoints,
      'last_game_at': lastGameAt?.toUtc().toIso8601String(),
      'elo_classical': classical.rating,
      'elo_rapid': rapid.rating,
      'elo_blitz': blitz.rating,
      'elo_bullet': bullet.rating,
      'peak_classical': classical.peak,
      'peak_rapid': rapid.peak,
      'peak_blitz': blitz.peak,
      'peak_bullet': bullet.peak,
      'games_classical': classical.gamesPlayed,
      'games_rapid': rapid.gamesPlayed,
      'games_blitz': blitz.gamesPlayed,
      'games_bullet': bullet.gamesPlayed,
      'wins_classical': classical.wins,
      'wins_rapid': rapid.wins,
      'wins_blitz': blitz.wins,
      'wins_bullet': bullet.wins,
      'losses_classical': classical.losses,
      'losses_rapid': rapid.losses,
      'losses_blitz': blitz.losses,
      'losses_bullet': bullet.losses,
      'draws_classical': classical.draws,
      'draws_rapid': rapid.draws,
      'draws_blitz': blitz.draws,
      'draws_bullet': bullet.draws,
    };
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
        ratings[tc] = PlayRatingStats(
          rating: (m['rating'] as num?)?.toInt() ?? 1200,
          peak: (m['peak'] as num?)?.toInt() ?? 1200,
          gamesPlayed: (m['gamesPlayed'] as num?)?.toInt() ?? 0,
          wins: (m['wins'] as num?)?.toInt() ?? 0,
          losses: (m['losses'] as num?)?.toInt() ?? 0,
          draws: (m['draws'] as num?)?.toInt() ?? 0,
        );
      }
    }

    PlayRatingStats statsFromSnake(String suffix) => PlayRatingStats(
      rating: readInt('elo_$suffix', 'elo_$suffix', 1200),
      peak: readInt('peak_$suffix', 'peak_$suffix', 1200),
      gamesPlayed: readInt('games_$suffix', 'games_$suffix', 0),
      wins: readInt('wins_$suffix', 'wins_$suffix', 0),
      losses: readInt('losses_$suffix', 'losses_$suffix', 0),
      draws: readInt('draws_$suffix', 'draws_$suffix', 0),
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
  });

  final DateTime playedAt;
  final int rating;
  final int delta;
  final int? opponentElo;
  final double score;
  final int kFactor;
  final String? gameKey;

  Map<String, dynamic> toLocalJson() => {
    'playedAt': playedAt.toUtc().toIso8601String(),
    'rating': rating,
    'delta': delta,
    'opponentElo': opponentElo,
    'score': score,
    'kFactor': kFactor,
    'gameKey': gameKey,
  };

  Map<String, dynamic> toSupabaseJson({
    required String userId,
    required RatedTimeControl tc,
  }) => {
    'user_id': userId,
    'time_control': tc.wire,
    'played_at': playedAt.toUtc().toIso8601String(),
    'rating': rating,
    'delta': delta,
    'opponent_elo': opponentElo,
    'score': score,
    'k_factor': kFactor,
    'game_key': gameKey,
  };

  static PlayRatingPoint fromJson(Map<String, dynamic> json) {
    int? readIntOpt(String camel, String snake) {
      final v = json[camel] ?? json[snake];
      if (v == null) return null;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
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
      score:
          (json['score'] is num)
              ? (json['score'] as num).toDouble()
              : double.tryParse(json['score']?.toString() ?? '') ?? 0,
      kFactor: readIntOpt('kFactor', 'k_factor') ?? 20,
      gameKey: (json['gameKey'] ?? json['game_key'])?.toString(),
    );
  }
}

class PlayProfileRepository {
  PlayProfileRepository({
    PlayGameAnalyzer analyzer = const PlayGameAnalyzer(),
    FideEloCalculator elo = const FideEloCalculator(),
  }) : _analyzer = analyzer,
       _elo = elo;

  final PlayGameAnalyzer _analyzer;
  final FideEloCalculator _elo;

  SupabaseClient? get _client {
    if (!DesktopSupabaseInit.isInitialized) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String get currentDisplayName {
    final user = _client?.auth.currentUser;
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    for (final key in const ['full_name', 'name', 'display_name']) {
      final text = metadata[key]?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    final email = user?.email?.trim();
    if (email != null && email.isNotEmpty) return email.split('@').first;
    return 'ChessEver Player';
  }

  Future<PlayUserProfile> fetchProfile() async {
    final local = await _readLocalProfile();
    final user = _client?.auth.currentUser;
    if (user != null) {
      try {
        final row =
            await _client!
                .from('user_play_profiles')
                .select()
                .eq('user_id', user.id)
                .maybeSingle();
        if (row != null) {
          final remote = PlayUserProfile.fromJson(row);
          if (local != null && _shouldPreferLocalProfile(local, remote)) {
            unawaited(saveProfile(local));
            return local;
          }
          unawaited(_writeLocalProfile(remote));
          return remote;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Play profile fetch failed: $e');
      }
    }
    return local ?? PlayUserProfile.fallback(currentDisplayName);
  }

  Future<void> saveProfile(PlayUserProfile profile) async {
    await _writeLocalProfile(profile);
    final user = _client?.auth.currentUser;
    if (user == null) return;
    try {
      await _client!
          .from('user_play_profiles')
          .upsert(profile.toSupabaseJson(user.id), onConflict: 'user_id');
    } catch (e) {
      if (kDebugMode) debugPrint('Play profile save failed: $e');
    }
  }

  Future<List<PlayGameRecord>> fetchRecentGames({int limit = 80}) async {
    final user = _client?.auth.currentUser;
    if (user != null) {
      try {
        final rows = await _client!
            .from('user_play_games')
            .select()
            .eq('user_id', user.id)
            .order('played_at', ascending: false)
            .limit(limit);
        final games = rows
            .map((row) => PlayGameRecord.fromJson(row))
            .toList(growable: false);
        unawaited(_mergeLocalGames(games));
        return games;
      } catch (e) {
        if (kDebugMode) debugPrint('Play games fetch failed: $e');
      }
    }
    return _readLocalGames(limit: limit);
  }

  /// Load the date-vs-rating curve points for one rated ladder, oldest
  /// first. Falls back to local cache when Supabase is unreachable.
  Future<List<PlayRatingPoint>> fetchRatingHistory(
    RatedTimeControl tc, {
    int limit = 500,
  }) async {
    final user = _client?.auth.currentUser;
    if (user != null) {
      try {
        final rows = await _client!
            .from('user_play_rating_history')
            .select()
            .eq('user_id', user.id)
            .eq('time_control', tc.wire)
            .order('played_at', ascending: true)
            .limit(limit);
        final points = rows
            .map(
              (row) => PlayRatingPoint.fromJson(Map<String, dynamic>.from(row)),
            )
            .toList(growable: false);
        unawaited(_writeLocalHistory(tc, points));
        return points;
      } catch (e) {
        if (kDebugMode) debugPrint('Rating history fetch failed: $e');
      }
    }
    return _readLocalHistory(tc);
  }

  Future<PlayGameRecord> saveCompletedGame(
    PlayGameRecord record, {
    PlayAchievementsState? achievements,
  }) async {
    final games = await _readLocalGames(limit: 1000);
    final existing = games.where(
      (game) => game.localGameKey == record.localGameKey,
    );
    final existingRecord = existing.isEmpty ? null : existing.first;
    final ratingAlreadyRecorded = existingRecord?.ratingAfter != null;
    var profile = await fetchProfile();
    var enriched =
        ratingAlreadyRecorded
            ? record.copyWith(
              ratingBefore: existingRecord!.ratingBefore,
              ratingAfter: existingRecord.ratingAfter,
            )
            : record;

    final tc = _ratedTcForRecord(record);
    PlayRatingPoint? historyPoint;

    if (!ratingAlreadyRecorded && record.userScore != null && tc != null) {
      final score = record.userScore!;
      final stats = profile.statsFor(tc);
      final opponent =
          record.opponentElo ??
          record.blackElo ??
          record.whiteElo ??
          stats.rating;
      final update = _elo.compute(
        currentRating: stats.rating,
        opponentRating: opponent,
        score: score,
        gamesPlayedBefore: stats.gamesPlayed,
        peakRating: stats.peak,
      );
      enriched = record.copyWith(
        ratingBefore: update.ratingBefore,
        ratingAfter: update.ratingAfter,
      );
      profile = profile.copyWithRating(
        tc,
        stats.applyResult(newRating: update.ratingAfter, score: score),
      );
      profile = profile.copyWith(
        lastGameAt: record.playedAt,
        achievementPoints:
            achievements?.unlocked.length ?? profile.achievementPoints,
      );
      historyPoint = PlayRatingPoint(
        playedAt: record.playedAt,
        rating: update.ratingAfter,
        delta: update.delta,
        opponentElo: opponent,
        score: score,
        kFactor: update.kFactor,
        gameKey: record.localGameKey,
      );
      await _writeLocalProfile(profile);
      await _appendLocalHistory(tc, historyPoint);
    }

    await _upsertLocalGame(enriched);

    final user = _client?.auth.currentUser;
    if (user != null) {
      try {
        await _client!
            .from('user_play_games')
            .upsert(
              enriched.toSupabaseJson(user.id),
              onConflict: 'user_id,local_game_key',
            );
        await _client!
            .from('user_play_profiles')
            .upsert(profile.toSupabaseJson(user.id), onConflict: 'user_id');
        if (historyPoint != null && tc != null) {
          await _client!
              .from('user_play_rating_history')
              .upsert(
                historyPoint.toSupabaseJson(userId: user.id, tc: tc),
                onConflict: 'user_id,time_control,game_key',
              );
        }
        if (achievements != null) {
          await _syncAchievementRows(user.id, achievements, enriched);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Play game Supabase save failed: $e');
      }
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

  Future<void> _syncAchievementRows(
    String userId,
    PlayAchievementsState achievements,
    PlayGameRecord record,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (final definition in kPlayAchievementDefinitions) {
      final progress = achievements.stats.progressFor(definition.id);
      final unlocked = achievements.unlocked.contains(definition.id);
      rows.add({
        'user_id': userId,
        'achievement_id': definition.id.name,
        'progress': progress,
        'unlocked_at':
            unlocked ? DateTime.now().toUtc().toIso8601String() : null,
        'latest_game_key': record.localGameKey,
        'metadata': {
          'title': definition.title,
          'target': definition.target,
          'lastBadgeIds': record.badgeIds,
        },
      });
    }
    await _client!
        .from('user_play_achievements')
        .upsert(rows, onConflict: 'user_id,achievement_id');
  }

  RatedTimeControl? _ratedTcForRecord(PlayGameRecord record) {
    final fromCategory = ratedTimeControlFromString(record.timeCategory);
    if (fromCategory != null) return fromCategory;
    final seconds = record.baseSeconds;
    if (seconds != null && seconds > 0) {
      return ratedTimeControlForSeconds(seconds);
    }
    return null;
  }

  Future<File> _profileFile() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'play_profile', 'profile.json'));
  }

  Future<File> _gamesFile() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'play_profile', 'games.json'));
  }

  Future<File> _historyFile(RatedTimeControl tc) async {
    final support = await getApplicationSupportDirectory();
    return File(
      p.join(support.path, 'play_profile', 'history_${tc.wire}.json'),
    );
  }

  PlayUserProfile? _readLocalProfileSync(File file) {
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return PlayUserProfile.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<PlayUserProfile?> _readLocalProfile() async {
    final file = await _profileFile();
    return _readLocalProfileSync(file);
  }

  Future<void> _writeLocalProfile(PlayUserProfile profile) async {
    final file = await _profileFile();
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(profile.toLocalJson()),
      flush: true,
    );
  }

  Future<List<PlayGameRecord>> _readLocalGames({required int limit}) async {
    final file = await _gamesFile();
    if (!await file.exists()) return const <PlayGameRecord>[];
    try {
      final json = jsonDecode(await file.readAsString()) as List<dynamic>;
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
      if (kDebugMode) debugPrint('Play local game read failed: $e');
      return const <PlayGameRecord>[];
    }
  }

  Future<void> _upsertLocalGame(PlayGameRecord record) async {
    final games = await _readLocalGames(limit: 1000);
    final byKey = {for (final game in games) game.localGameKey: game};
    byKey[record.localGameKey] = record;
    final next =
        byKey.values.toList()..sort((a, b) => b.playedAt.compareTo(a.playedAt));
    final file = await _gamesFile();
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(next.take(500).map((g) => g.toLocalJson()).toList()),
      flush: true,
    );
  }

  Future<void> _mergeLocalGames(List<PlayGameRecord> games) async {
    for (final game in games) {
      await _upsertLocalGame(game);
    }
  }

  Future<List<PlayRatingPoint>> _readLocalHistory(RatedTimeControl tc) async {
    final file = await _historyFile(tc);
    if (!await file.exists()) return const <PlayRatingPoint>[];
    try {
      final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
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
      if (kDebugMode) debugPrint('Rating history local read failed: $e');
      return const <PlayRatingPoint>[];
    }
  }

  Future<void> _writeLocalHistory(
    RatedTimeControl tc,
    List<PlayRatingPoint> points,
  ) async {
    final file = await _historyFile(tc);
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    final sorted = [...points]
      ..sort((a, b) => a.playedAt.compareTo(b.playedAt));
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sorted.map((p) => p.toLocalJson()).toList()),
      flush: true,
    );
  }

  Future<void> _appendLocalHistory(
    RatedTimeControl tc,
    PlayRatingPoint point,
  ) async {
    final existing = await _readLocalHistory(tc);
    final byKey = <String, PlayRatingPoint>{
      for (final p in existing)
        if (p.gameKey != null) p.gameKey!: p,
    };
    if (point.gameKey != null) {
      byKey[point.gameKey!] = point;
      final merged = byKey.values.toList();
      // Re-add any history points that had no game key.
      for (final p in existing) {
        if (p.gameKey == null) merged.add(p);
      }
      await _writeLocalHistory(tc, merged);
    } else {
      await _writeLocalHistory(tc, [...existing, point]);
    }
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
