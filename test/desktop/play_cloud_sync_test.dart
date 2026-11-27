import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_cloud_sync.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_local_store.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';

/// Columns of `public.user_play_profiles` on the live project (read
/// 2026-11-27, after `20261127120000_play_cloud_sync.sql`).
const _liveProfileColumns = {
  'user_id',
  'display_name',
  'avatar_seed',
  'current_elo',
  'games_played',
  'wins',
  'losses',
  'draws',
  'achievement_points',
  'last_game_at',
  'created_at',
  'updated_at',
  'elo_classical',
  'elo_rapid',
  'elo_blitz',
  'elo_bullet',
  'peak_classical',
  'peak_rapid',
  'peak_blitz',
  'peak_bullet',
  'games_classical',
  'games_rapid',
  'games_blitz',
  'games_bullet',
  'wins_classical',
  'wins_rapid',
  'wins_blitz',
  'wins_bullet',
  'losses_classical',
  'losses_rapid',
  'losses_blitz',
  'losses_bullet',
  'draws_classical',
  'draws_rapid',
  'draws_blitz',
  'draws_bullet',
  'rd_bullet',
  'rd_blitz',
  'rd_rapid',
  'rd_classical',
  'volatility_bullet',
  'volatility_blitz',
  'volatility_rapid',
  'volatility_classical',
  'last_played_bullet',
  'last_played_blitz',
  'last_played_rapid',
  'last_played_classical',
  'rewards',
  'rewards_updated_at',
  'settings',
  'settings_updated_at',
};

/// Columns of `public.user_play_rating_history` on the live project.
const _liveHistoryColumns = {
  'id',
  'user_id',
  'time_control',
  'played_at',
  'rating',
  'delta',
  'opponent_elo',
  'score',
  'k_factor',
  'game_key',
  'created_at',
  'rd',
  'volatility',
};

/// Columns of `public.user_play_achievements` on the live project.
const _liveAchievementColumns = {
  'user_id',
  'achievement_id',
  'progress',
  'unlocked_at',
  'latest_game_key',
  'metadata',
  'created_at',
  'updated_at',
};

class _MemoryStore extends PlayLocalStore {
  _MemoryStore();

  final Map<String, String> files = {};

  @override
  Future<String?> read(String relativePath) async => files[relativePath];

  @override
  Future<void> write(String relativePath, String contents) async {
    files[relativePath] = contents;
  }
}

/// An in-memory `user_play_*` schema with upsert-merge semantics (only the
/// columns sent are written, like PostgREST's merge-duplicates).
class _FakeGateway implements PlayCloudGateway {
  PlayCloudUser? user;
  final Map<String, Map<String, dynamic>> profiles = {};
  final Map<String, Map<String, dynamic>> games = {};
  final Map<String, Map<String, dynamic>> history = {};
  final Map<String, Map<String, dynamic>> achievements = {};
  final Set<String> failing = {};

  /// Set to hold the next profile upsert until it completes.
  Completer<void>? holdProfileUpsert;
  final Completer<void> profileUpsertHeld = Completer<void>();

  /// Profile reads never answer (a stalled connection).
  bool hangProfileReads = false;

  void _maybeFail(String table) {
    if (failing.contains(table)) throw StateError('$table is down');
  }

  @override
  PlayCloudUser? get currentUser => user;

  @override
  Future<Map<String, dynamic>?> fetchProfileRow(String userId) async {
    _maybeFail('profiles.read');
    if (hangProfileReads) await Completer<void>().future;
    final row = profiles[userId];
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<void> upsertProfile(Map<String, dynamic> row) async {
    _maybeFail('profiles');
    if (row.containsKey('display_name')) _maybeFail('profiles.full');
    expect(row.keys.toSet().difference(_liveProfileColumns), isEmpty);
    final hold = holdProfileUpsert;
    if (hold != null) {
      holdProfileUpsert = null;
      profileUpsertHeld.complete();
      await hold.future;
    }
    final existing =
        profiles[row['user_id']] ??
        {
          'display_name': 'ChessEver Player',
          'avatar_seed': 'server-default',
          'rewards': <String, dynamic>{},
          'settings': <String, dynamic>{},
        };
    profiles[row['user_id'] as String] = {...existing, ...row};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchGameIndex(String userId) async {
    _maybeFail('games.read');
    return [
      for (final row in games.values)
        if (row['user_id'] == userId)
          {
            'local_game_key': row['local_game_key'],
            'played_at': row['played_at'],
          },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchGamesByKeys(
    String userId,
    List<String> keys,
  ) async {
    _maybeFail('games.read');
    return [
      for (final key in keys)
        if (games['$userId|$key'] != null) games['$userId|$key']!,
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRecentGames(
    String userId,
    int limit,
  ) async {
    _maybeFail('games.read');
    return games.values
        .where((row) => row['user_id'] == userId)
        .take(limit)
        .toList();
  }

  @override
  Future<void> upsertGames(List<Map<String, dynamic>> rows) async {
    _maybeFail('games');
    for (final row in rows) {
      games['${row['user_id']}|${row['local_game_key']}'] = row;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchHistory(
    String userId, {
    RatedTimeControl? tc,
  }) async {
    _maybeFail('history.read');
    return [
      for (final row in history.values)
        if (row['user_id'] == userId &&
            (tc == null || row['time_control'] == tc.wire))
          row,
    ];
  }

  @override
  Future<void> upsertHistory(List<Map<String, dynamic>> rows) async {
    _maybeFail('history');
    for (final row in rows) {
      expect(row.keys.toSet().difference(_liveHistoryColumns), isEmpty);
      expect(row['k_factor'] as int, greaterThan(0));
      history['${row['user_id']}|${row['time_control']}|${row['game_key']}'] =
          row;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchAchievementRows(String userId) async {
    _maybeFail('achievements.read');
    return [
      for (final row in achievements.values)
        if (row['user_id'] == userId) row,
    ];
  }

  @override
  Future<void> upsertAchievementRows(List<Map<String, dynamic>> rows) async {
    _maybeFail('achievements');
    for (final row in rows) {
      expect(row.keys.toSet().difference(_liveAchievementColumns), isEmpty);
      achievements['${row['user_id']}|${row['achievement_id']}'] = row;
    }
  }
}

PlayGameRecord _game(
  String key, {
  required DateTime at,
  String result = '1-0',
  String timeCategory = 'blitz',
  int opponentElo = 1400,
  int? ratingBefore,
  int? ratingAfter,
}) {
  return PlayGameRecord(
    localGameKey: key,
    source: PlayGameSource.singlePlay,
    playedAt: at,
    result: result,
    endReason: 'checkmate',
    startingFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    finalFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    movesUci: const ['e2e4'],
    pgn: '1. e4 1-0',
    pgnHeaders: const {},
    metadata: const {},
    analysis: const {},
    badgeContributions: const [],
    timeCategory: timeCategory,
    baseSeconds: 300,
    humanColor: 'white',
    opponentElo: opponentElo,
    ratingBefore: ratingBefore,
    ratingAfter: ratingAfter,
  );
}

PlayRatingStats _ladder({
  required int rating,
  required int games,
  DateTime? at,
  double? rd,
}) {
  return PlayRatingStats(
    rating: rating,
    peak: rating,
    gamesPlayed: games,
    wins: games,
    losses: 0,
    draws: 0,
    rd: rd,
    volatility: rd == null ? null : 0.059,
    lastPlayedAt: at,
  );
}

Map<String, dynamic> _syncState(_MemoryStore store) =>
    jsonDecode(store.files[kPlaySyncStatePath]!) as Map<String, dynamic>;

void main() {
  group('row shapes match the live schema', () {
    test('profile row carries every client column and nothing unknown', () {
      final row = PlayUserProfile.fallback('Ana').toSupabaseJson('u1');
      const serverOwned = {
        'created_at',
        'updated_at',
        'rewards',
        'rewards_updated_at',
        'settings',
        'settings_updated_at',
      };
      expect(row.keys.toSet(), _liveProfileColumns.difference(serverOwned));
      expect(row['display_name'], 'Ana');
      expect(row['avatar_seed'], isNotEmpty);
    });

    test('profile row never sends an empty name and stays inside CHECKs', () {
      final profile = PlayUserProfile.fallback('x')
          .copyWith(displayName: '  ', avatarSeed: '')
          .copyWithRating(
            RatedTimeControl.bullet,
            _ladder(rating: 40, games: 3),
          );
      final row = profile.toSupabaseJson('u1');
      expect(row['display_name'], 'ChessEver Player');
      expect(row['avatar_seed'], isNotEmpty);
      expect(row['elo_bullet'], 100);
    });

    test('Glicko state round-trips through the profile row', () {
      final at = DateTime.utc(2026, 11, 20, 18, 30);
      final profile = PlayUserProfile.fallback('Ana').copyWithRating(
        RatedTimeControl.rapid,
        _ladder(rating: 1432, games: 12, at: at, rd: 97.5),
      );
      final back = PlayUserProfile.fromJson(profile.toSupabaseJson('u1'));
      final rapid = back.ratings[RatedTimeControl.rapid]!;
      expect(rapid.rating, 1432);
      expect(rapid.rd, 97.5);
      expect(rapid.volatility, 0.059);
      expect(rapid.lastPlayedAt!.isAtSameMomentAs(at), isTrue);
      // A ladder never played sends no Glicko state.
      final row = profile.toSupabaseJson('u1');
      expect(row['rd_bullet'], isNull);
      expect(row['last_played_bullet'], isNull);
    });

    test('history row has rd and volatility and a valid k_factor', () {
      final point = PlayRatingPoint(
        playedAt: DateTime.utc(2026, 11, 1),
        rating: 1210,
        delta: 0,
        opponentElo: 1200,
        score: 0.5,
        kFactor: 0,
        gameKey: 'g1',
        rd: 120.5,
        volatility: 0.06,
      );
      final row = point.toSupabaseJson(
        userId: 'u1',
        tc: RatedTimeControl.blitz,
      );
      expect(
        row.keys.toSet(),
        _liveHistoryColumns.difference({'id', 'created_at'}),
      );
      expect(row['k_factor'], 1);
      expect(row['rd'], 120.5);
      expect(row['volatility'], 0.06);
      expect(PlayRatingPoint.fromJson(row).volatility, 0.06);
    });
  });

  group('merge rules', () {
    final older = DateTime.utc(2026, 11, 1);
    final newer = DateTime.utc(2026, 11, 2);

    test('a newer local ladder beats an older server row', () {
      final local = _ladder(rating: 1300, games: 10, at: newer, rd: 90);
      final remote = _ladder(rating: 1250, games: 11, at: older, rd: 80);
      expect(mergePlayLadder(local, remote).rating, 1300);
    });

    test('a newer server ladder beats a stale local one', () {
      final local = _ladder(rating: 1300, games: 10, at: older, rd: 90);
      final remote = _ladder(rating: 1350, games: 12, at: newer, rd: 80);
      expect(mergePlayLadder(local, remote).rating, 1350);
    });

    test('undated legacy rows fall back to the game count', () {
      final local = _ladder(rating: 1300, games: 10, rd: 90);
      final remote = _ladder(rating: 1200, games: 4);
      expect(mergePlayLadder(local, remote).rating, 1300);
      expect(mergePlayLadder(remote, local).rating, 1300);
    });

    test('same games: a legacy winner borrows the other copy\'s RD', () {
      final local = _ladder(rating: 1300, games: 10, rd: 90);
      final remote = _ladder(rating: 1300, games: 10);
      expect(mergePlayLadder(remote, local).rd, 90);
    });

    test('profiles merge per ladder, server name unless edited here', () {
      final local = PlayUserProfile.fallback('Local name')
          .copyWithRating(
            RatedTimeControl.blitz,
            _ladder(rating: 1300, games: 5, at: newer),
          )
          .copyWithRating(
            RatedTimeControl.rapid,
            _ladder(rating: 1100, games: 2, at: older),
          );
      final remote = PlayUserProfile.fallback('Server name')
          .copyWithRating(
            RatedTimeControl.blitz,
            _ladder(rating: 1250, games: 4, at: older),
          )
          .copyWithRating(
            RatedTimeControl.rapid,
            _ladder(rating: 1180, games: 3, at: newer),
          );
      final merged = mergePlayProfiles(local: local, remote: remote);
      expect(merged.ratings[RatedTimeControl.blitz]!.rating, 1300);
      expect(merged.ratings[RatedTimeControl.rapid]!.rating, 1180);
      expect(merged.displayName, 'Server name');
      expect(
        mergePlayProfiles(
          local: local,
          remote: remote,
          preferLocalIdentity: true,
        ).displayName,
        'Local name',
      );
    });

    test('rewards: the newer state wins, deterministic on ties', () {
      final a = PlayAchievementsState(
        stats: const PlayAchievementStats(gamesPlayed: 3, xp: 100),
        unlocked: const {},
        updatedAt: newer,
      );
      final b = PlayAchievementsState(
        stats: const PlayAchievementStats(gamesPlayed: 5, xp: 300),
        unlocked: const {},
        updatedAt: older,
      );
      expect(
        decidePlayRewardsWinner(local: a, remote: b, remoteUpdatedAt: older),
        PlayRewardsWinner.local,
      );
      expect(
        decidePlayRewardsWinner(local: b, remote: a, remoteUpdatedAt: newer),
        PlayRewardsWinner.remote,
      );
      expect(
        decidePlayRewardsWinner(local: a, remote: a, remoteUpdatedAt: newer),
        PlayRewardsWinner.none,
      );
      // An undated (pre-sync) local state loses to a dated server state
      // unless it holds more XP.
      final legacy = b.copyWith();
      final legacyUndated = PlayAchievementsState(
        stats: legacy.stats,
        unlocked: const {},
      );
      expect(
        decidePlayRewardsWinner(
          local: legacyUndated,
          remote: a,
          remoteUpdatedAt: newer,
        ),
        PlayRewardsWinner.local,
      );
      expect(
        decidePlayRewardsWinner(local: null, remote: a, remoteUpdatedAt: newer),
        PlayRewardsWinner.remote,
      );
    });

    test('the rewards JSON round-trips, earned times included', () {
      final state = PlayAchievementsState(
        stats: const PlayAchievementStats(gamesPlayed: 12, wins: 6, xp: 640),
        unlocked: const {PlayAchievementId.firstGame},
        claimable: const {PlayAchievementId.fiveWins},
        earnedAt: {PlayAchievementId.firstGame: older.toLocal()},
        updatedAt: newer.toLocal(),
      );
      final json = encodePlayRewardsState(state);
      expect(json['level'], greaterThan(1));
      expect((json['tiers'] as Map)['games'], 2);
      final back = decodePlayRewardsState(jsonDecode(jsonEncode(json)))!;
      expect(back.stats.xp, 640);
      expect(back.unlocked, {PlayAchievementId.firstGame});
      expect(back.claimable, {PlayAchievementId.fiveWins});
      expect(
        back.earnedAt[PlayAchievementId.firstGame]!.isAtSameMomentAs(older),
        isTrue,
      );
      expect(back.updatedAt!.isAtSameMomentAs(newer), isTrue);
    });

    test('unlocked_at keeps the first unlock, not the time of the sync', () {
      final first = DateTime.utc(2026, 6, 1);
      final now = DateTime.utc(2026, 11, 27);
      final state = PlayAchievementsState(
        stats: const PlayAchievementStats(gamesPlayed: 3, wins: 1),
        unlocked: const {PlayAchievementId.firstGame},
        claimable: const {PlayAchievementId.firstWin},
        earnedAt: {PlayAchievementId.firstWin: DateTime.utc(2026, 7, 1)},
      );
      final plan = buildPlayAchievementRows(
        userId: 'u1',
        state: state,
        serverRows: [
          {
            'achievement_id': 'firstGame',
            'progress': 2,
            'unlocked_at': first.toIso8601String(),
            'metadata': {'claimed': true},
          },
        ],
        now: now,
      );
      final byId = {for (final r in plan.rows) r['achievement_id']: r};
      expect(
        DateTime.parse(
          byId['firstGame']!['unlocked_at'],
        ).isAtSameMomentAs(first),
        isTrue,
      );
      expect(
        DateTime.parse(
          byId['firstWin']!['unlocked_at'],
        ).isAtSameMomentAs(DateTime.utc(2026, 7, 1)),
        isTrue,
      );
      expect(byId['fiftyGames']!['unlocked_at'], isNull);
      // The server's time is learnt locally so it never moves again.
      expect(
        plan.assignedEarnedAt[PlayAchievementId.firstGame]!.isAtSameMomentAs(
          first,
        ),
        isTrue,
      );

      // Rows that already match the server are not sent again.
      final again = buildPlayAchievementRows(
        userId: 'u1',
        state: state,
        serverRows: plan.rows,
        now: now.add(const Duration(days: 1)),
      );
      expect(again.rows, isEmpty);
    });

    test('rated games without a point get one rebuilt', () {
      final games = [
        _game(
          'g1',
          at: DateTime.utc(2026, 9, 1),
          ratingBefore: 1200,
          ratingAfter: 1230,
        ),
        _game('g2', at: DateTime.utc(2026, 9, 2)), // no rating: skipped
      ];
      final points = synthesizePlayRatingPoints(
        RatedTimeControl.blitz,
        games,
        const [],
      );
      expect(points, hasLength(1));
      expect(points.single.delta, 30);
      expect(points.single.kFactor, greaterThan(0));
    });

    test('an outbox state from before the edit counter still reads', () {
      final legacy = PlaySyncState.fromJson({'profileEdited': true});
      expect(legacy.profileEdited, isTrue);
      final sent = legacy.withProfileEditsUploaded(legacy.profileEdits);
      expect(sent.profileEdited, isFalse);
      // An edit made after the upload read the profile stays pending.
      final later = legacy.withProfileEdit().withProfileEditsUploaded(1);
      expect(later.profileEdited, isTrue);
      expect(PlaySyncState.fromJson(later.toJson()).profileEdited, isTrue);
    });

    test('owner rules adopt unowned and guest data, switch for others', () {
      expect(
        decidePlayOwnerAction(PlaySyncState.empty, 'a'),
        PlayOwnerAction.adopt,
      );
      expect(
        decidePlayOwnerAction(
          const PlaySyncState(ownerUserId: 'guest', ownerIsAnonymous: true),
          'a',
        ),
        PlayOwnerAction.adopt,
      );
      expect(
        decidePlayOwnerAction(const PlaySyncState(ownerUserId: 'a'), 'a'),
        PlayOwnerAction.keep,
      );
      expect(
        decidePlayOwnerAction(const PlaySyncState(ownerUserId: 'b'), 'a'),
        PlayOwnerAction.switchAccount,
      );
    });
  });

  group('repository sync', () {
    late _MemoryStore store;
    late _FakeGateway gateway;
    late PlayProfileRepository repository;

    setUp(() {
      store = _MemoryStore();
      gateway = _FakeGateway();
      repository = PlayProfileRepository(
        store: store,
        gateway: gateway,
        clock: () => DateTime.utc(2026, 11, 27, 12),
      );
    });

    test('games played signed out are uploaded on sign-in', () async {
      final saved = await repository.saveCompletedGame(
        _game('g1', at: DateTime.utc(2026, 11, 26, 10)),
      );
      expect(saved.ratingAfter, isNotNull);
      expect(_syncState(store)['dirtyGames'], ['g1']);
      store.files[kPlayAchievementsStatePath] = jsonEncode(
        encodePlayRewardsState(
          PlayAchievementsState(
            stats: const PlayAchievementStats(gamesPlayed: 1, wins: 1, xp: 50),
            unlocked: const {},
            claimable: const {PlayAchievementId.firstGame},
            updatedAt: DateTime.utc(2026, 11, 26, 10),
          ),
        ),
      );

      gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
      final report = await repository.syncNow();

      expect(report.failures, isEmpty);
      expect(gateway.games.keys, ['u1|g1']);
      expect(gateway.history.keys, ['u1|blitz|g1']);
      expect(gateway.history['u1|blitz|g1']!['rd'], isNotNull);
      final profile = gateway.profiles['u1']!;
      expect(profile['display_name'], isNotEmpty);
      expect(profile['games_blitz'], 1);
      expect(profile['rd_blitz'], isNotNull);
      expect(profile['last_played_blitz'], isNotNull);
      expect((profile['rewards'] as Map)['xp'], 50);
      expect(profile['rewards_updated_at'], isNotNull);
      expect(gateway.achievements['u1|firstGame']!['unlocked_at'], isNotNull);
      expect(_syncState(store)['dirtyGames'], isEmpty);
      expect(_syncState(store)['dirtyHistory'], isEmpty);
      expect(_syncState(store)['ownerUserId'], 'u1');
    });

    test(
      'one failing table never stops the others; the outbox retries',
      () async {
        gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
        gateway.failing.addAll({'games', 'history'});
        await repository.saveCompletedGame(
          _game('g1', at: DateTime.utc(2026, 11, 26, 10)),
        );
        final first = await repository.syncNow();
        expect(first.failures, isNotEmpty);
        expect(gateway.games, isEmpty);
        // The profile still went up.
        expect(gateway.profiles['u1']!['games_blitz'], 1);
        expect(_syncState(store)['dirtyGames'], ['g1']);

        gateway.failing.clear();
        final second = await repository.syncNow(full: false);
        expect(second.failures, isEmpty);
        expect(gateway.games.keys, ['u1|g1']);
        expect(gateway.history.keys, ['u1|blitz|g1']);
        expect(_syncState(store)['dirtyGames'], isEmpty);
      },
    );

    test(
      'a full pass pulls server games and points this device lacks',
      () async {
        gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
        final remoteGame = _game(
          'remote-1',
          at: DateTime.utc(2026, 10, 1),
          ratingBefore: 1200,
          ratingAfter: 1225,
        );
        gateway.games['u1|remote-1'] = remoteGame.toSupabaseJson('u1');
        // A game whose rating point never reached the server.
        final orphan = _game(
          'remote-2',
          at: DateTime.utc(2026, 10, 2),
          ratingBefore: 1225,
          ratingAfter: 1250,
        );
        gateway.games['u1|remote-2'] = orphan.toSupabaseJson('u1');
        gateway.history['u1|blitz|remote-1'] = PlayRatingPoint(
          playedAt: DateTime.utc(2026, 10, 1),
          rating: 1225,
          delta: 25,
          opponentElo: 1400,
          score: 1,
          kFactor: 40,
          gameKey: 'remote-1',
        ).toSupabaseJson(userId: 'u1', tc: RatedTimeControl.blitz);

        final report = await repository.syncNow();
        expect(report.gamesPulled, 2);
        final games = await repository.fetchRecentGames();
        expect(games.map((g) => g.localGameKey), ['remote-2', 'remote-1']);
        final points = await repository.fetchRatingHistory(
          RatedTimeControl.blitz,
        );
        expect(points.map((p) => p.gameKey), ['remote-1', 'remote-2']);
        // The rebuilt point was uploaded too.
        expect(gateway.history.containsKey('u1|blitz|remote-2'), isTrue);
        // The empty profile was rebuilt from the games and the row created.
        expect(gateway.profiles['u1']!['elo_blitz'], 1250);
        expect(gateway.profiles['u1']!['games_blitz'], 2);
      },
    );

    test('rewards upload writes only the rewards columns', () async {
      gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
      gateway.profiles['u1'] = {
        'user_id': 'u1',
        'display_name': 'Server name',
        'avatar_seed': 'seed',
        'settings': {'helpStyle': 'coach'},
        'settings_updated_at': '2026-11-01T00:00:00.000Z',
        'rewards': <String, dynamic>{},
      };
      store.files[kPlayAchievementsStatePath] = jsonEncode(
        encodePlayRewardsState(
          PlayAchievementsState(
            stats: const PlayAchievementStats(gamesPlayed: 4, xp: 120),
            unlocked: const {},
            updatedAt: DateTime.utc(2026, 11, 20),
          ),
        ),
      );
      await repository.syncNow(full: false);
      final row = gateway.profiles['u1']!;
      expect((row['rewards'] as Map)['xp'], 120);
      expect(row['settings'], {'helpStyle': 'coach'});
      expect(row['display_name'], 'Server name');
    });

    test('a newer server rewards state replaces the local one', () async {
      gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
      final serverState = PlayAchievementsState(
        stats: const PlayAchievementStats(gamesPlayed: 9, xp: 900),
        unlocked: const {PlayAchievementId.firstGame},
        updatedAt: DateTime.utc(2026, 11, 25),
      );
      gateway.profiles['u1'] = {
        'user_id': 'u1',
        'display_name': 'Ana',
        'avatar_seed': 'seed',
        'rewards': encodePlayRewardsState(serverState),
        'rewards_updated_at': '2026-11-25T00:00:00.000Z',
      };
      store.files[kPlayAchievementsStatePath] = jsonEncode(
        encodePlayRewardsState(
          PlayAchievementsState(
            stats: const PlayAchievementStats(gamesPlayed: 2, xp: 60),
            unlocked: const {},
            updatedAt: DateTime.utc(2026, 11, 20),
          ),
        ),
      );
      final report = await repository.syncNow(full: false);
      expect(report.rewardsPulled, isTrue);
      final local =
          decodePlayRewardsState(
            jsonDecode(store.files[kPlayAchievementsStatePath]!),
          )!;
      expect(local.stats.xp, 900);
    });

    test('another account\'s games are never uploaded to this one', () async {
      gateway.user = const PlayCloudUser(id: 'alice', displayName: 'Alice');
      gateway.failing.add('games');
      await repository.saveCompletedGame(
        _game('alice-game', at: DateTime.utc(2026, 11, 26)),
      );
      await repository.syncNow();
      gateway.failing.clear();

      gateway.user = const PlayCloudUser(id: 'bob', displayName: 'Bob');
      await repository.syncNow();
      expect(gateway.games.keys.where((k) => k.startsWith('bob|')), isEmpty);
      expect(await repository.fetchRecentGames(), isEmpty);

      // Alice signs back in: her stashed game is restored and uploaded.
      gateway.user = const PlayCloudUser(id: 'alice', displayName: 'Alice');
      await repository.syncNow();
      expect(gateway.games.keys, contains('alice|alice-game'));
    });

    test('a guest\'s games move to the account it signs in to', () async {
      gateway.user = const PlayCloudUser(id: 'guest', isAnonymous: true);
      await repository.saveCompletedGame(
        _game('guest-game', at: DateTime.utc(2026, 11, 26)),
      );
      await repository.syncNow();
      expect(gateway.games.keys, ['guest|guest-game']);

      await repository.adoptGuestPlayData(
        guestUserId: 'guest',
        targetUserId: 'account',
      );
      gateway.user = const PlayCloudUser(id: 'account', displayName: 'Ana');
      await repository.syncNow();
      expect(gateway.games.keys, contains('account|guest-game'));
      expect(gateway.history.keys, contains('account|blitz|guest-game'));
      expect(gateway.profiles['account']!['games_blitz'], 1);
    });

    test('settings never seed a new account from another account\'s '
        'documents', () async {
      gateway.user = const PlayCloudUser(id: 'alice', displayName: 'Alice');
      gateway.failing.add('profiles');
      await repository.saveCompletedGame(
        _game('alice-game', at: DateTime.utc(2026, 11, 26)),
      );
      await repository.syncNow();
      gateway.failing.clear();
      expect(_syncState(store)['ownerUserId'], 'alice');

      // Bob signs in; the settings sync runs before any Play pass.
      gateway.user = const PlayCloudUser(id: 'bob', displayName: 'Bob');
      await repository.saveSettings({'v': 1}, DateTime.utc(2026, 11, 27));
      final row = gateway.profiles['bob']!;
      expect(row['display_name'], 'Bob');
      expect(row['games_blitz'], 0);
      expect(row['settings'], {'v': 1});
      expect(_syncState(store)['ownerUserId'], 'bob');
      expect(await repository.fetchRecentGames(), isEmpty);
    });

    test('rewards never create a default profile row', () async {
      gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
      store.files[kPlayAchievementsStatePath] = jsonEncode(
        encodePlayRewardsState(
          PlayAchievementsState(
            stats: const PlayAchievementStats(gamesPlayed: 1, xp: 50),
            unlocked: const {},
            updatedAt: DateTime.utc(2026, 11, 26),
          ),
        ),
      );
      gateway.failing.add('profiles.full');
      final report = await repository.syncNow(full: false);
      expect(report.failures, isNotEmpty);
      expect(gateway.profiles, isEmpty);

      gateway.failing.clear();
      await repository.syncNow(full: false);
      final row = gateway.profiles['u1']!;
      expect(row['display_name'], 'Ana');
      expect(row['avatar_seed'], 'local-player');
      expect((row['rewards'] as Map)['xp'], 50);
    });

    test('settings fail without a known profile row', () async {
      gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
      gateway.failing.add('profiles.read');
      await expectLater(
        repository.saveSettings({'v': 1}, DateTime.utc(2026, 11, 27)),
        throwsStateError,
      );
      gateway.failing
        ..clear()
        ..add('profiles.full');
      await expectLater(
        repository.saveSettings({'v': 1}, DateTime.utc(2026, 11, 27)),
        throwsStateError,
      );
      expect(gateway.profiles, isEmpty);
    });

    test('an account back after a guest gets its stash and outbox', () async {
      gateway.user = const PlayCloudUser(id: 'alice', displayName: 'Alice');
      gateway.failing.addAll({'games', 'history'});
      await repository.saveCompletedGame(
        _game('alice-offline', at: DateTime.utc(2026, 11, 20)),
      );
      await repository.syncNow();
      gateway.failing.clear();
      expect(_syncState(store)['dirtyGames'], ['alice-offline']);

      // Signed out; the next launch starts a guest, which plays a game.
      gateway.user = const PlayCloudUser(id: 'guest', isAnonymous: true);
      await repository.syncNow();
      expect(store.files[playSyncStashPath('alice')], isNotEmpty);
      await repository.saveCompletedGame(
        _game('guest-game', at: DateTime.utc(2026, 11, 26)),
      );
      await repository.syncNow();

      gateway.user = const PlayCloudUser(id: 'alice', displayName: 'Alice');
      final report = await repository.syncNow();
      expect(report.failures, isEmpty);
      expect(store.files[playSyncStashPath('alice')], isEmpty);
      expect(
        gateway.games.keys,
        containsAll(['alice|alice-offline', 'alice|guest-game']),
      );
      expect(
        gateway.history.keys,
        containsAll(['alice|blitz|alice-offline', 'alice|blitz|guest-game']),
      );
      expect(gateway.profiles['alice']!['games_blitz'], 2);
      expect(gateway.profiles['alice']!['display_name'], 'Alice');
      expect(_syncState(store)['dirtyGames'], isEmpty);
      expect(_syncState(store)['adoptedFromGuest'], isNull);
    });

    test('a guest signing in to an existing account keeps the account\'s '
        'ladders and rewards', () async {
      final accountRewards = PlayAchievementsState(
        stats: const PlayAchievementStats(gamesPlayed: 300, xp: 9000),
        unlocked: const {PlayAchievementId.firstGame},
        updatedAt: DateTime.utc(2026, 11, 20),
      );
      gateway.profiles['account'] = {
        ...PlayUserProfile.fallback('Ana')
            .copyWithRating(
              RatedTimeControl.blitz,
              _ladder(
                rating: 1850,
                games: 300,
                at: DateTime.utc(2026, 11, 20),
                rd: 60,
              ),
            )
            .toSupabaseJson('account'),
        'avatar_seed': 'account-seed',
        'rewards': encodePlayRewardsState(accountRewards),
        'rewards_updated_at': '2026-11-20T00:00:00.000Z',
      };

      gateway.user = const PlayCloudUser(id: 'guest', isAnonymous: true);
      await repository.saveCompletedGame(
        _game('guest-game', at: DateTime.utc(2026, 11, 26)),
      );
      store.files[kPlayAchievementsStatePath] = jsonEncode(
        encodePlayRewardsState(
          PlayAchievementsState(
            stats: const PlayAchievementStats(gamesPlayed: 1, xp: 50),
            unlocked: const {},
            updatedAt: DateTime.utc(2026, 11, 26),
          ),
        ),
      );
      await repository.syncNow();

      await repository.adoptGuestPlayData(
        guestUserId: 'guest',
        targetUserId: 'account',
      );
      gateway.user = const PlayCloudUser(id: 'account', displayName: 'Ana');
      final report = await repository.syncNow();
      expect(report.failures, isEmpty);

      final row = gateway.profiles['account']!;
      // The guest's win is rated on top of the account's 1850.
      expect(row['games_blitz'], 301);
      expect(row['elo_blitz'] as int, greaterThan(1850));
      expect(row['avatar_seed'], 'account-seed');
      expect((row['rewards'] as Map)['xp'], 9000);
      final game = gateway.games['account|guest-game']!;
      expect(game['rating_before'], 1850);
      final point = gateway.history['account|blitz|guest-game']!;
      expect(point['rating'], row['elo_blitz']);
      final local =
          decodePlayRewardsState(
            jsonDecode(store.files[kPlayAchievementsStatePath]!),
          )!;
      expect(local.stats.xp, 9000);
    });

    test('a profile edit during a pass is never lost', () async {
      gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
      await repository.syncNow();
      final hold = Completer<void>();
      gateway.holdProfileUpsert = hold;
      final pass = repository.syncNow(full: false);
      await gateway.profileUpsertHeld.future; // the pass uploads 'Ana'

      final profile = await repository.fetchProfile();
      final edit = repository.saveProfile(
        profile.copyWith(displayName: 'Renamed'),
      );
      await Future<void>.delayed(Duration.zero);
      hold.complete();
      await pass;
      await edit;

      expect(gateway.profiles['u1']!['display_name'], 'Renamed');
      expect((await repository.fetchProfile()).displayName, 'Renamed');
      expect(_syncState(store)['profileEdited'], isFalse);
    });

    test('a stalled server never holds a finished game back', () async {
      final quick = PlayProfileRepository(
        store: store,
        gateway: gateway,
        serverMergeTimeout: const Duration(milliseconds: 50),
      );
      gateway
        ..user = const PlayCloudUser(id: 'u1', displayName: 'Ana')
        ..hangProfileReads = true;
      final saved = await quick
          .saveCompletedGame(_game('g1', at: DateTime.utc(2026, 11, 26)))
          .timeout(const Duration(seconds: 2));
      expect(saved.ratingAfter, isNotNull);
      expect(_syncState(store)['dirtyGames'], ['g1']);
      expect(_syncState(store)['dirtyHistory'], ['blitz|g1']);
    });

    test('settings API reads and writes only the settings columns', () async {
      expect(await repository.fetchSettings(), isNull); // signed out
      gateway.user = const PlayCloudUser(id: 'u1', displayName: 'Ana');
      expect(await repository.fetchSettings(), isNull); // no row yet
      final at = DateTime.utc(2026, 11, 27, 9);
      await repository.saveSettings({'helpStyle': 'quiet'}, at);
      final row = gateway.profiles['u1']!;
      expect(row['settings'], {'helpStyle': 'quiet'});
      expect(row['display_name'], 'Ana');
      final read = await repository.fetchSettings();
      expect(read!['settings'], {'helpStyle': 'quiet'});
      expect(
        DateTime.parse(read['settings_updated_at']).isAtSameMomentAs(at),
        isTrue,
      );
    });
  });
}
