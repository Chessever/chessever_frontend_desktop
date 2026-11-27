import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_cloud_signals.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_glicko.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_rewards.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';

/// Play mode in the cloud: the rules that keep this device's Play documents
/// and the account's `user_play_*` rows in step. The repository
/// (`PlayProfileRepository`) runs them; this file holds the server gateway,
/// the outbox state and the merge rules, all pure enough to unit test.
///
/// Contract: `docs/play_supabase_schema.md` and
/// `supabase/migrations/20261127120000_play_cloud_sync.sql`.

void playSyncLog(String message) => debugPrint('[PlaySync] $message');

// ---------------------------------------------------------------------------
// Gateway
// ---------------------------------------------------------------------------

@immutable
class PlayCloudUser {
  const PlayCloudUser({
    required this.id,
    this.isAnonymous = false,
    this.displayName,
  });

  final String id;
  final bool isAnonymous;

  /// From the auth metadata (full name, name, e-mail local part).
  final String? displayName;
}

/// The server side of Play sync. Every method throws on failure; callers
/// log and carry on, so one failing table never stops another.
abstract interface class PlayCloudGateway {
  PlayCloudUser? get currentUser;

  Future<Map<String, dynamic>?> fetchProfileRow(String userId);

  /// Upsert on `user_id`. Only the columns in [row] are written, so a row
  /// without `rewards` or `settings` never touches those.
  Future<void> upsertProfile(Map<String, dynamic> row);

  /// Every game's `local_game_key` and `played_at`, all pages.
  Future<List<Map<String, dynamic>>> fetchGameIndex(String userId);

  Future<List<Map<String, dynamic>>> fetchGamesByKeys(
    String userId,
    List<String> keys,
  );

  Future<List<Map<String, dynamic>>> fetchRecentGames(String userId, int limit);

  /// Upsert on `user_id,local_game_key`.
  Future<void> upsertGames(List<Map<String, dynamic>> rows);

  /// Rating points, oldest first, all pages. [tc] limits to one ladder.
  Future<List<Map<String, dynamic>>> fetchHistory(
    String userId, {
    RatedTimeControl? tc,
  });

  /// Upsert on `user_id,time_control,game_key`.
  Future<void> upsertHistory(List<Map<String, dynamic>> rows);

  Future<List<Map<String, dynamic>>> fetchAchievementRows(String userId);

  /// Upsert on `user_id,achievement_id`.
  Future<void> upsertAchievementRows(List<Map<String, dynamic>> rows);
}

class SupabasePlayCloudGateway implements PlayCloudGateway {
  const SupabasePlayCloudGateway();

  static const int _pageSize = 1000;
  static const int _keyChunk = 50;
  static const int _writeChunk = 20;

  SupabaseClient? get _client {
    if (!DesktopSupabaseInit.isInitialized) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  SupabaseClient get _requireClient {
    final client = _client;
    if (client == null) throw StateError('Supabase is not initialized');
    return client;
  }

  @override
  PlayCloudUser? get currentUser {
    final user = _client?.auth.currentUser;
    if (user == null) return null;
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    String? name;
    for (final key in const ['full_name', 'name', 'display_name']) {
      final text = metadata[key]?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        name = text;
        break;
      }
    }
    final email = user.email?.trim();
    if (name == null && email != null && email.isNotEmpty) {
      name = email.split('@').first;
    }
    return PlayCloudUser(
      id: user.id,
      isAnonymous: user.isAnonymous,
      displayName: name,
    );
  }

  @override
  Future<Map<String, dynamic>?> fetchProfileRow(String userId) async {
    final row =
        await _requireClient
            .from('user_play_profiles')
            .select()
            .eq('user_id', userId)
            .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<void> upsertProfile(Map<String, dynamic> row) async {
    await _requireClient
        .from('user_play_profiles')
        .upsert(row, onConflict: 'user_id');
  }

  @override
  Future<List<Map<String, dynamic>>> fetchGameIndex(String userId) async {
    final rows = <Map<String, dynamic>>[];
    for (var from = 0; ; from += _pageSize) {
      final page = await _requireClient
          .from('user_play_games')
          .select('local_game_key, played_at')
          .eq('user_id', userId)
          .order('played_at', ascending: false)
          .order('local_game_key', ascending: true)
          .range(from, from + _pageSize - 1);
      rows.addAll(page.map((row) => Map<String, dynamic>.from(row)));
      if (page.length < _pageSize) return rows;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchGamesByKeys(
    String userId,
    List<String> keys,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < keys.length; i += _keyChunk) {
      final chunk = keys.sublist(i, math.min(i + _keyChunk, keys.length));
      final page = await _requireClient
          .from('user_play_games')
          .select()
          .eq('user_id', userId)
          .inFilter('local_game_key', chunk);
      rows.addAll(page.map((row) => Map<String, dynamic>.from(row)));
    }
    return rows;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRecentGames(
    String userId,
    int limit,
  ) async {
    final page = await _requireClient
        .from('user_play_games')
        .select()
        .eq('user_id', userId)
        .order('played_at', ascending: false)
        .limit(limit);
    return page.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  @override
  Future<void> upsertGames(List<Map<String, dynamic>> rows) async {
    for (var i = 0; i < rows.length; i += _writeChunk) {
      await _requireClient
          .from('user_play_games')
          .upsert(
            rows.sublist(i, math.min(i + _writeChunk, rows.length)),
            onConflict: 'user_id,local_game_key',
          );
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchHistory(
    String userId, {
    RatedTimeControl? tc,
  }) async {
    final rows = <Map<String, dynamic>>[];
    for (var from = 0; ; from += _pageSize) {
      var query = _requireClient
          .from('user_play_rating_history')
          .select()
          .eq('user_id', userId);
      if (tc != null) query = query.eq('time_control', tc.wire);
      final page = await query
          .order('played_at', ascending: true)
          .order('id', ascending: true)
          .range(from, from + _pageSize - 1);
      rows.addAll(page.map((row) => Map<String, dynamic>.from(row)));
      if (page.length < _pageSize) return rows;
    }
  }

  @override
  Future<void> upsertHistory(List<Map<String, dynamic>> rows) async {
    for (var i = 0; i < rows.length; i += 200) {
      await _requireClient
          .from('user_play_rating_history')
          .upsert(
            rows.sublist(i, math.min(i + 200, rows.length)),
            onConflict: 'user_id,time_control,game_key',
          );
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchAchievementRows(String userId) async {
    final page = await _requireClient
        .from('user_play_achievements')
        .select()
        .eq('user_id', userId);
    return page.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  @override
  Future<void> upsertAchievementRows(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    await _requireClient
        .from('user_play_achievements')
        .upsert(rows, onConflict: 'user_id,achievement_id');
  }
}

// ---------------------------------------------------------------------------
// Outbox state
// ---------------------------------------------------------------------------

/// What this device still owes the server, and whose data its Play
/// documents are. Saved at [kPlaySyncStatePath].
///
/// Play documents on a device are not split per account. [ownerUserId] is
/// the account they belong to: null while nobody signed in has played (or
/// before this state existed). Signing in adopts an unowned or guest-owned
/// set; signing in as a different permanent account stashes the previous
/// owner's set and restores the new account's own.
@immutable
class PlaySyncState {
  const PlaySyncState({
    this.ownerUserId,
    this.ownerIsAnonymous = false,
    this.dirtyGames = const <String>{},
    this.dirtyHistory = const <String>{},
    this.profileEdits = 0,
    this.profileEditsUploaded = 0,
    this.adoptedFromGuest = false,
    this.adoptedGuestKeys = const <String>{},
    this.adoptedOverAccountData = false,
  });

  static const PlaySyncState empty = PlaySyncState();

  final String? ownerUserId;
  final bool ownerIsAnonymous;

  /// Games saved or changed here and not yet confirmed on the server.
  final Set<String> dirtyGames;

  /// Rating points not yet confirmed, as `<ladder>|<game key>`.
  final Set<String> dirtyHistory;

  /// How many times the player renamed or re-seeded the avatar here, and
  /// how many of those edits an upload carried. A counter, not a flag, so
  /// an upload that read the profile before an edit never marks that edit
  /// as sent.
  final int profileEdits;
  final int profileEditsUploaded;

  /// The documents came from this device's guest and now belong to a
  /// permanent account. Until the next pass resolves it against the
  /// account's server profile, the guest's ladders and rewards are not
  /// the account's: they never win over the server by date.
  final bool adoptedFromGuest;

  /// Keys of the games the guest played (rated again on top of the
  /// account's ladders when the account already has some).
  final Set<String> adoptedGuestKeys;

  /// The account's own stashed documents were restored under the guest's:
  /// the local profile and rewards are the account's, not the guest's.
  final bool adoptedOverAccountData;

  /// The player edited the profile here and the edit is not uploaded yet;
  /// the next profile upload keeps this device's name over the server's.
  bool get profileEdited => profileEdits > profileEditsUploaded;

  bool get hasPending =>
      dirtyGames.isNotEmpty || dirtyHistory.isNotEmpty || profileEdited;

  static String historyKey(RatedTimeControl tc, String gameKey) =>
      '${tc.wire}|$gameKey';

  /// One more profile edit made here.
  PlaySyncState withProfileEdit() =>
      copyWith(profileEdits: math.max(profileEdits, profileEditsUploaded) + 1);

  /// An upload carried every edit up to [edits] (read before it merged).
  PlaySyncState withProfileEditsUploaded(int edits) =>
      copyWith(profileEditsUploaded: math.max(profileEditsUploaded, edits));

  PlaySyncState copyWith({
    String? ownerUserId,
    bool clearOwner = false,
    bool? ownerIsAnonymous,
    Set<String>? dirtyGames,
    Set<String>? dirtyHistory,
    int? profileEdits,
    int? profileEditsUploaded,
    bool? adoptedFromGuest,
    Set<String>? adoptedGuestKeys,
    bool? adoptedOverAccountData,
  }) {
    return PlaySyncState(
      ownerUserId: clearOwner ? null : (ownerUserId ?? this.ownerUserId),
      ownerIsAnonymous: ownerIsAnonymous ?? this.ownerIsAnonymous,
      dirtyGames: dirtyGames ?? this.dirtyGames,
      dirtyHistory: dirtyHistory ?? this.dirtyHistory,
      profileEdits: profileEdits ?? this.profileEdits,
      profileEditsUploaded: profileEditsUploaded ?? this.profileEditsUploaded,
      adoptedFromGuest: adoptedFromGuest ?? this.adoptedFromGuest,
      adoptedGuestKeys: adoptedGuestKeys ?? this.adoptedGuestKeys,
      adoptedOverAccountData:
          adoptedOverAccountData ?? this.adoptedOverAccountData,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    if (ownerUserId != null) 'ownerUserId': ownerUserId,
    'ownerIsAnonymous': ownerIsAnonymous,
    'dirtyGames': dirtyGames.toList()..sort(),
    'dirtyHistory': dirtyHistory.toList()..sort(),
    'profileEdited': profileEdited,
    'profileEdits': profileEdits,
    'profileEditsUploaded': profileEditsUploaded,
    if (adoptedFromGuest) 'adoptedFromGuest': true,
    if (adoptedGuestKeys.isNotEmpty)
      'adoptedGuestKeys': adoptedGuestKeys.toList()..sort(),
    if (adoptedOverAccountData) 'adoptedOverAccountData': true,
  };

  static PlaySyncState fromJson(Map<dynamic, dynamic> json) {
    Set<String> strings(Object? raw) =>
        raw is List ? raw.map((e) => e.toString()).toSet() : <String>{};
    int count(Object? raw) => raw is num && raw > 0 ? raw.toInt() : 0;
    final owner = json['ownerUserId']?.toString();
    var edits = count(json['profileEdits']);
    final uploaded = count(json['profileEditsUploaded']);
    // A state written before the counters kept only the flag.
    if (!json.containsKey('profileEdits') && json['profileEdited'] == true) {
      edits = 1;
    }
    return PlaySyncState(
      ownerUserId: owner == null || owner.isEmpty ? null : owner,
      ownerIsAnonymous: json['ownerIsAnonymous'] == true,
      dirtyGames: strings(json['dirtyGames']),
      dirtyHistory: strings(json['dirtyHistory']),
      profileEdits: edits,
      profileEditsUploaded: uploaded,
      adoptedFromGuest: json['adoptedFromGuest'] == true,
      adoptedGuestKeys: strings(json['adoptedGuestKeys']),
      adoptedOverAccountData: json['adoptedOverAccountData'] == true,
    );
  }
}

const String kPlaySyncStatePath = 'play_sync/state.json';
String playSyncStashPath(String userId) => 'play_sync/stash_$userId.json';

/// What the device should do when [current] signs in and the documents
/// belong to [state.ownerUserId].
enum PlayOwnerAction { keep, adopt, switchAccount }

PlayOwnerAction decidePlayOwnerAction(PlaySyncState state, String userId) {
  final owner = state.ownerUserId;
  if (owner == userId) return PlayOwnerAction.keep;
  // Played signed out, before this state existed, or as this device's
  // guest: it is the same person signing in, so the account takes it.
  if (owner == null || state.ownerIsAnonymous) return PlayOwnerAction.adopt;
  return PlayOwnerAction.switchAccount;
}

// ---------------------------------------------------------------------------
// Merge rules
// ---------------------------------------------------------------------------

/// True when [local]'s ladder should win over [remote]'s.
///
/// The newer `lastPlayedAt` wins, so a newer local rating is never lost to
/// an older server row and a stale local one never beats a newer server
/// one. Ladders without a date (saved before Glicko-2) fall back to the
/// game count; on a full tie the local copy wins.
bool playLocalLadderWins(PlayRatingStats local, PlayRatingStats remote) {
  final lt = local.lastPlayedAt;
  final rt = remote.lastPlayedAt;
  if (lt != null && rt != null) {
    if (!lt.isAtSameMomentAs(rt)) return lt.isAfter(rt);
    return local.gamesPlayed >= remote.gamesPlayed;
  }
  if (local.gamesPlayed != remote.gamesPlayed) {
    return local.gamesPlayed > remote.gamesPlayed;
  }
  return lt != null || rt == null;
}

PlayRatingStats mergePlayLadder(PlayRatingStats local, PlayRatingStats remote) {
  final localWins = playLocalLadderWins(local, remote);
  final winner = localWins ? local : remote;
  final loser = localWins ? remote : local;
  // Same games, but only one copy knows the Glicko state: keep it.
  if (winner.rd == null &&
      loser.rd != null &&
      winner.gamesPlayed == loser.gamesPlayed) {
    return winner.withGlickoFrom(loser);
  }
  return winner;
}

/// [local] and [remote] merged ladder by ladder ([mergePlayLadder]).
///
/// Name and avatar come from the server unless [preferLocalIdentity] (the
/// player edited them on this device and the edit is not uploaded yet).
PlayUserProfile mergePlayProfiles({
  required PlayUserProfile local,
  required PlayUserProfile? remote,
  bool preferLocalIdentity = false,
}) {
  if (remote == null) return local;
  final ratings = <RatedTimeControl, PlayRatingStats>{
    for (final tc in RatedTimeControl.values)
      tc: mergePlayLadder(
        local.ratings[tc] ?? PlayRatingStats.initial,
        remote.ratings[tc] ?? PlayRatingStats.initial,
      ),
  };
  final useLocalName = preferLocalIdentity || remote.displayName.trim().isEmpty;
  final useLocalAvatar =
      preferLocalIdentity ||
      remote.avatarSeed.trim().isEmpty ||
      (remote.avatarSeed == 'local-player' &&
          local.avatarSeed != 'local-player');
  DateTime? latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  DateTime? earliest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isBefore(b) ? a : b;
  }

  return PlayUserProfile(
    displayName: useLocalName ? local.displayName : remote.displayName,
    avatarSeed: useLocalAvatar ? local.avatarSeed : remote.avatarSeed,
    ratings: ratings,
    achievementPoints: math.max(
      local.achievementPoints,
      remote.achievementPoints,
    ),
    lastGameAt: latest(local.lastGameAt, remote.lastGameAt),
    createdAt: earliest(local.createdAt, remote.createdAt),
  );
}

/// Ladders that hold no games while rated games for them exist (a new
/// device, or an account whose profile row never reached the server) are
/// rebuilt from those games: the latest rating, the peak and the results.
PlayUserProfile rebuildEmptyLaddersFromGames(
  PlayUserProfile profile,
  Iterable<PlayGameRecord> games,
) {
  final byTc = <RatedTimeControl, List<PlayGameRecord>>{};
  for (final game in games) {
    final tc = playRatedTcForRecord(game);
    if (tc == null || game.ratingAfter == null || game.userScore == null) {
      continue;
    }
    byTc.putIfAbsent(tc, () => []).add(game);
  }
  var next = profile;
  for (final entry in byTc.entries) {
    final current = profile.ratings[entry.key] ?? PlayRatingStats.initial;
    if (current.gamesPlayed > 0) continue;
    final list = [...entry.value]
      ..sort((a, b) => a.playedAt.compareTo(b.playedAt));
    var peak = kPlayInitialRating;
    var wins = 0, losses = 0, draws = 0;
    for (final game in list) {
      peak = math.max(peak, game.ratingAfter!);
      final score = game.userScore!;
      if (score == 1) wins++;
      if (score == 0) losses++;
      if (score == 0.5) draws++;
    }
    next = next.copyWithRating(
      entry.key,
      PlayRatingStats(
        rating: list.last.ratingAfter!.clamp(kPlayMinRating, kPlayMaxRating),
        peak: peak.clamp(kPlayMinRating, kPlayMaxRating),
        gamesPlayed: list.length,
        wins: wins,
        losses: losses,
        draws: draws,
        lastPlayedAt: list.last.playedAt,
      ),
    );
    if (next.lastGameAt == null ||
        list.last.playedAt.isAfter(next.lastGameAt!)) {
      next = next.copyWith(lastGameAt: list.last.playedAt);
    }
  }
  return next;
}

/// The rated ladder a saved game counts on, or null for an unrated clock.
RatedTimeControl? playRatedTcForRecord(PlayGameRecord record) {
  final fromCategory = ratedTimeControlFromString(record.timeCategory);
  if (fromCategory != null) return fromCategory;
  final seconds = record.baseSeconds;
  if (seconds != null && seconds > 0) {
    return ratedTimeControlForSeconds(seconds);
  }
  return null;
}

/// Union of two point lists by game key; the local point fills in the RD
/// and volatility the other copy lacks. Unkeyed points stay as they are.
List<PlayRatingPoint> mergePlayRatingPoints(
  List<PlayRatingPoint> local,
  List<PlayRatingPoint> remote,
) {
  final byKey = <String, PlayRatingPoint>{};
  final unkeyed = <PlayRatingPoint>[];
  for (final point in remote) {
    final key = point.gameKey;
    if (key == null) continue; // the server never stores unkeyed points
    byKey[key] = point;
  }
  for (final point in local) {
    final key = point.gameKey;
    if (key == null) {
      unkeyed.add(point);
      continue;
    }
    final theirs = byKey[key];
    byKey[key] =
        theirs == null
            ? point
            : theirs.copyWith(
              rd: theirs.rd ?? point.rd,
              volatility: theirs.volatility ?? point.volatility,
            );
  }
  return [...byKey.values, ...unkeyed]
    ..sort((a, b) => a.playedAt.compareTo(b.playedAt));
}

/// One point per rated game in [games] that [existing] lacks, rebuilt from
/// the game's own rating before and after.
List<PlayRatingPoint> synthesizePlayRatingPoints(
  RatedTimeControl tc,
  Iterable<PlayGameRecord> games,
  Iterable<PlayRatingPoint> existing,
) {
  final known = {
    for (final p in existing)
      if (p.gameKey != null) p.gameKey!,
  };
  final points = <PlayRatingPoint>[];
  for (final game in games) {
    if (playRatedTcForRecord(game) != tc) continue;
    if (known.contains(game.localGameKey)) continue;
    final before = game.ratingBefore;
    final after = game.ratingAfter;
    final score = game.userScore;
    if (before == null || after == null || score == null) continue;
    final opponent = game.opponentElo;
    final delta = after - before;
    final expected =
        opponent == null
            ? 0.5
            : 1 / (1 + math.pow(10, (opponent - before) / 400).toDouble());
    final surprise = (score - expected).abs();
    points.add(
      PlayRatingPoint(
        playedAt: game.playedAt,
        rating: after,
        delta: delta,
        opponentElo: opponent,
        score: score,
        kFactor:
            surprise < 0.01 ? 1 : math.max(1, (delta / surprise).abs().round()),
        gameKey: game.localGameKey,
      ),
    );
  }
  return points;
}

/// Union of two game lists by `localGameKey`. When both hold a game, the
/// one that carries a rating (then an analysis) wins; otherwise the local
/// copy wins when it changed here ([dirtyKeys]), else the server's.
List<PlayGameRecord> mergePlayGameRecords(
  List<PlayGameRecord> local,
  List<PlayGameRecord> remote, {
  Set<String> dirtyKeys = const <String>{},
}) {
  int weight(PlayGameRecord g) =>
      (g.ratingAfter != null ? 2 : 0) + (g.analysis.isNotEmpty ? 1 : 0);
  final byKey = <String, PlayGameRecord>{
    for (final game in remote) game.localGameKey: game,
  };
  for (final game in local) {
    final theirs = byKey[game.localGameKey];
    if (theirs == null) {
      byKey[game.localGameKey] = game;
      continue;
    }
    final mine = weight(game), other = weight(theirs);
    if (mine > other ||
        (mine == other && dirtyKeys.contains(game.localGameKey))) {
      byKey[game.localGameKey] = game;
    }
  }
  return byKey.values.toList()
    ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
}

enum PlayRewardsWinner { none, local, remote }

/// Which rewards state should stand: the newer `updatedAt` wins. A state
/// with no date (saved before the sync existed) loses to a dated one
/// unless it holds more XP; with no dates at all the larger XP wins and a
/// tie keeps the local copy. Empty states always lose.
PlayRewardsWinner decidePlayRewardsWinner({
  required PlayAchievementsState? local,
  required PlayAchievementsState? remote,
  required DateTime? remoteUpdatedAt,
}) {
  bool isEmpty(PlayAchievementsState? s) =>
      s == null ||
      (s.stats.gamesPlayed == 0 &&
          s.stats.xp == 0 &&
          s.unlocked.isEmpty &&
          s.claimable.isEmpty &&
          s.stats.tournamentsCreated == 0);
  final localEmpty = isEmpty(local), remoteEmpty = isEmpty(remote);
  if (localEmpty && remoteEmpty) return PlayRewardsWinner.none;
  if (remoteEmpty) return PlayRewardsWinner.local;
  if (localEmpty) return PlayRewardsWinner.remote;
  final lt = local!.updatedAt;
  final rt = remoteUpdatedAt ?? remote!.updatedAt;
  if (lt != null && rt != null) {
    if (lt.isAtSameMomentAs(rt)) return PlayRewardsWinner.none;
    return lt.isAfter(rt) ? PlayRewardsWinner.local : PlayRewardsWinner.remote;
  }
  if (lt != null) return PlayRewardsWinner.local;
  if (rt != null) {
    return local.stats.xp > remote!.stats.xp
        ? PlayRewardsWinner.local
        : PlayRewardsWinner.remote;
  }
  return local.stats.xp >= remote!.stats.xp
      ? PlayRewardsWinner.local
      : PlayRewardsWinner.remote;
}

/// The `user_play_achievements` rows for [state]: one per badge, with
/// `unlocked_at` the first time it was earned. That time is the earlier of
/// the server's value and this device's ([PlayAchievementsState.earnedAt]);
/// a badge earned with neither (saved before either existed) gets [now]
/// once, and [assignedEarnedAt] reports it so the caller can keep it.
@immutable
class PlayAchievementRowsPlan {
  const PlayAchievementRowsPlan({
    required this.rows,
    required this.assignedEarnedAt,
  });

  /// Only the rows that differ from the server.
  final List<Map<String, dynamic>> rows;
  final Map<PlayAchievementId, DateTime> assignedEarnedAt;
}

PlayAchievementRowsPlan buildPlayAchievementRows({
  required String userId,
  required PlayAchievementsState state,
  required List<Map<String, dynamic>> serverRows,
  required DateTime now,
  String? latestGameKey,
}) {
  final server = <String, Map<String, dynamic>>{
    for (final row in serverRows) row['achievement_id'].toString(): row,
  };
  final assigned = <PlayAchievementId, DateTime>{};
  final rows = <Map<String, dynamic>>[];
  for (final definition in kPlayAchievementDefinitions) {
    final id = definition.id;
    final progress = math.max(0, state.stats.progressFor(id));
    final claimed = state.unlocked.contains(id);
    final earned =
        claimed ||
        state.claimable.contains(id) ||
        progress >= definition.target;
    final existing = server[id.name];
    final serverAt = DateTime.tryParse(
      existing?['unlocked_at']?.toString() ?? '',
    );
    final localAt = state.earnedAt[id];
    DateTime? unlockedAt;
    if (serverAt != null && localAt != null) {
      unlockedAt = serverAt.isBefore(localAt) ? serverAt : localAt;
    } else {
      unlockedAt = serverAt ?? localAt;
    }
    if (unlockedAt == null && earned) {
      unlockedAt = now;
    }
    if (earned && unlockedAt != null && localAt == null) {
      assigned[id] = unlockedAt;
    }
    final unlockedIso = unlockedAt?.toUtc().toIso8601String();
    final track = _trackFor(id);
    final metadata = <String, dynamic>{
      'title': definition.title,
      'target': definition.target,
      'claimed': claimed,
      if (track != null) 'track': track.key,
      if (track != null) 'tier': track.tierFor(track.progress(state.stats)),
    };
    final serverMeta = existing?['metadata'];
    final unchanged =
        existing != null &&
        (existing['progress'] as num?)?.toInt() == progress &&
        _sameInstant(existing['unlocked_at'], unlockedAt) &&
        serverMeta is Map &&
        serverMeta['claimed'] == claimed &&
        serverMeta['tier'] == metadata['tier'];
    if (unchanged) continue;
    rows.add({
      'user_id': userId,
      'achievement_id': id.name,
      'progress': progress,
      'unlocked_at': unlockedIso,
      'latest_game_key': latestGameKey ?? existing?['latest_game_key'],
      'metadata': metadata,
    });
  }
  return PlayAchievementRowsPlan(rows: rows, assignedEarnedAt: assigned);
}

PlayBadgeTrack? _trackFor(PlayAchievementId id) {
  for (final track in kPlayBadgeTracks) {
    if (track.ids.contains(id)) return track;
  }
  return null;
}

bool _sameInstant(Object? raw, DateTime? at) {
  final parsed = DateTime.tryParse(raw?.toString() ?? '');
  if (parsed == null || at == null) return parsed == null && at == null;
  return parsed.isAtSameMomentAs(at);
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

/// How long after launch the first full sync waits, so it stays out of the
/// first frames.
const Duration kPlayCloudSyncLaunchDelay = Duration(seconds: 8);

/// Keeps Play in step with the server: a full sync (upload everything the
/// server lacks, pull everything this device lacks) on launch with an
/// account and on every sign-in or account switch, and a quick push a few
/// seconds after any local change. Watched by the shell, main window only.
final playCloudSyncProvider = Provider<void>((ref) {
  if (ref.watch(desktopWindowRoleProvider) != DesktopWindowRole.main) return;
  if (!DesktopSupabaseInit.isInitialized) return;
  final auth = Supabase.instance.client.auth;
  final repository = ref.watch(playProfileRepositoryProvider);
  String? syncedUserId;
  Timer? soon;

  void refreshViews() {
    ref.invalidate(playUserProfileProvider);
    ref.invalidate(playRecentGamesProvider);
    ref.invalidate(playRatingHistoryProvider);
  }

  void fullFor(String? userId) {
    if (userId == null || userId == syncedUserId) return;
    syncedUserId = userId;
    unawaited(
      repository.syncNow(full: true).then((report) {
        if (report.changedLocal) refreshViews();
      }),
    );
  }

  final launch = Timer(
    kPlayCloudSyncLaunchDelay,
    () => fullFor(auth.currentUser?.id),
  );
  final authSub = auth.onAuthStateChange.listen((event) {
    final userId = event.session?.user.id;
    if (userId == null) {
      syncedUserId = null;
      return;
    }
    if (launch.isActive) return;
    fullFor(userId);
  }, onError: (Object e) => playSyncLog('auth event: $e'));
  final changedSub = PlayCloudSignals.localChanged.listen((_) {
    soon?.cancel();
    soon = Timer(const Duration(seconds: 3), () {
      unawaited(repository.syncNow(full: false));
    });
  });
  final replacedSub = PlayCloudSignals.localReplaced.listen(
    (_) => refreshViews(),
  );
  ref.onDispose(() {
    launch.cancel();
    soon?.cancel();
    unawaited(authSub.cancel());
    unawaited(changedSub.cancel());
    unawaited(replacedSub.cancel());
  });
});
