import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

enum PlayedTournamentStatus {
  running,
  stopped,
  aborted,
  completed;

  String get label => switch (this) {
    PlayedTournamentStatus.running => 'Live',
    PlayedTournamentStatus.stopped => 'Stopped',
    PlayedTournamentStatus.aborted => 'Aborted',
    PlayedTournamentStatus.completed => 'Completed',
  };

  static PlayedTournamentStatus fromName(String value) {
    return PlayedTournamentStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => PlayedTournamentStatus.stopped,
    );
  }
}

@immutable
class PlayedTournamentEvent {
  const PlayedTournamentEvent({
    required this.id,
    required this.title,
    required this.format,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    required this.participantCount,
    required this.gameCount,
    required this.finishedGameCount,
    required this.userGameCount,
    required this.userFinishedGameCount,
    required this.userScore,
  });

  final String id;
  final String title;
  final TournamentFormat format;
  final PlayedTournamentStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final int participantCount;
  final int gameCount;
  final int finishedGameCount;
  final int userGameCount;
  final int userFinishedGameCount;
  final double userScore;

  bool get hasUserGames => userGameCount > 0;
}

/// The server side of played events: one `public.user_play_tournaments` row
/// per event and signed-in account, so any ChessEver frontend can show them.
///
/// An interface so tests can run the sync without a Supabase client.
abstract class PlayTournamentRemote {
  /// The account rows are written for, or null when nobody is signed in.
  String? get currentUserId;

  /// Whether [currentUserId] is this device's guest (an anonymous user).
  bool get currentUserIsAnonymous;

  /// Inserts or updates [rows] on `(user_id, local_event_key)`.
  Future<void> upsert(List<Map<String, Object?>> rows);

  /// One page of the account's rows, newest first: rows `[from, to]`.
  Future<List<Map<String, Object?>>> fetchPage({
    required String userId,
    required int from,
    required int to,
  });
}

class SupabasePlayTournamentRemote implements PlayTournamentRemote {
  const SupabasePlayTournamentRemote();

  static const String table = 'user_play_tournaments';

  SupabaseClient? get _client {
    if (!DesktopSupabaseInit.isInitialized) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  @override
  String? get currentUserId => _client?.auth.currentUser?.id;

  @override
  bool get currentUserIsAnonymous =>
      _client?.auth.currentUser?.isAnonymous == true;

  @override
  Future<void> upsert(List<Map<String, Object?>> rows) async {
    final client = _client;
    if (client == null || rows.isEmpty) return;
    await client
        .from(table)
        .upsert(rows, onConflict: 'user_id,local_event_key');
  }

  @override
  Future<List<Map<String, Object?>>> fetchPage({
    required String userId,
    required int from,
    required int to,
  }) async {
    final client = _client;
    if (client == null) return const [];
    final rows = await client
        .from(table)
        .select(
          'local_event_key,title,format,status,started_at,finished_at,'
          'rounds,players,user_rank,user_score,snapshot,updated_at',
        )
        .eq('user_id', userId)
        .order('updated_at', ascending: false)
        .range(from, to);
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }
}

class PlayTournamentHistoryRepository {
  PlayTournamentHistoryRepository(
    AppDatabase db, {
    PlayTournamentRemote remote = const SupabasePlayTournamentRemote(),
    DateTime Function()? clock,
  }) : this.withOpener(() => db.database, remote: remote, clock: clock);

  /// Reads and writes the table through [open]; tests pass an in-memory
  /// database here.
  PlayTournamentHistoryRepository.withOpener(
    Future<Database> Function() open, {
    PlayTournamentRemote remote = const SupabasePlayTournamentRemote(),
    DateTime Function()? clock,
  }) : _openDatabase = open,
       _remote = remote,
       _clock = clock ?? DateTime.now;

  final Future<Database> Function() _openDatabase;
  final PlayTournamentRemote _remote;
  final DateTime Function() _clock;

  static const String _table = 'desktop_play_tournament_events';

  /// Rows sent per upsert request while draining the outbox.
  static const int uploadBatchSize = 50;

  /// Rows read per request while merging server events.
  static const int mergePageSize = 200;

  /// The longest a merge stays fresh before [fetchEvents] reads the server
  /// again for the same account.
  static const Duration mergeFreshFor = Duration(minutes: 5);

  Future<void>? _ready;
  Future<int>? _flushing;
  Future<int>? _merging;
  String? _mergedUserId;
  DateTime? _mergedAt;

  Future<Database> _open() async {
    final db = await _openDatabase();
    await (_ready ??= _ensureTable(db).catchError((Object e) {
      _ready = null;
      throw e;
    }));
    return db;
  }

  /// Saves [snapshot] on this device and starts uploading it for the
  /// signed-in account. The upload never blocks the local save; pass
  /// [awaitUpload] to wait for it (it never throws).
  Future<void> upsertSnapshot(
    TournamentSnapshot snapshot, {
    required PlayedTournamentStatus status,
    bool awaitUpload = false,
  }) async {
    final db = await _open();
    final now = _clock().toUtc();
    final existing = await db.query(
      _table,
      columns: const ['created_at', 'owner_user_id', 'owner_is_guest'],
      where: 'id = ?',
      whereArgs: [snapshot.config.id],
      limit: 1,
    );
    final createdAt =
        existing.isEmpty
            ? now
            : DateTime.fromMillisecondsSinceEpoch(
              existing.first['created_at'] as int,
              isUtc: true,
            );
    final summary = _summaryFor(snapshot);
    await db.insert(_table, {
      'id': snapshot.config.id,
      'title': snapshot.config.title,
      'format': snapshot.config.format.name,
      'status': status.name,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
      'completed_at':
          status == PlayedTournamentStatus.completed
              ? now.millisecondsSinceEpoch
              : null,
      'participant_count': snapshot.config.participants.length,
      'game_count': snapshot.games.length,
      'finished_game_count': summary.finishedGameCount,
      'user_game_count': summary.userGameCount,
      'user_finished_game_count': summary.userFinishedGameCount,
      'user_score': summary.userScore,
      'snapshot_json': jsonEncode(_snapshotToJson(snapshot)),
      'synced': 0,
      'owner_user_id':
          existing.isEmpty ? null : existing.first['owner_user_id'],
      'owner_is_guest':
          existing.isEmpty ? 0 : (existing.first['owner_is_guest'] ?? 0),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final upload = flushOutbox();
    if (awaitUpload) await upload;
  }

  Future<List<PlayedTournamentEvent>> fetchEvents({int limit = 120}) async {
    final db = await _open();
    final userId = _remote.currentUserId;
    if (userId != null && _mergeIsStale(userId)) {
      await mergeRemoteEvents();
    }
    final rows = await db.query(
      _table,
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(_eventFromRow).toList(growable: false);
  }

  bool _mergeIsStale(String userId) {
    final at = _mergedAt;
    if (_mergedUserId != userId || at == null) return true;
    return _clock().difference(at) >= mergeFreshFor;
  }

  /// Uploads every event not yet on the server for the signed-in account.
  /// Events played signed out belong to whoever signs in next; an event
  /// already uploaded for another account stays with that account.
  ///
  /// Returns how many events were uploaded. Never throws: a failure is
  /// logged and the events stay in the outbox for the next attempt.
  Future<int> flushOutbox() {
    final running = _flushing;
    if (running != null) {
      // A save made during a flush must not wait for the next trigger.
      return running.then((_) => _startFlush());
    }
    return _startFlush();
  }

  Future<int> _startFlush() {
    final running = _flushing;
    if (running != null) return running;
    final flush = _flush().whenComplete(() => _flushing = null);
    _flushing = flush;
    return flush;
  }

  Future<int> _flush() async {
    final userId = _remote.currentUserId;
    if (userId == null) return 0;
    final isGuest = _remote.currentUserIsAnonymous;
    try {
      final db = await _open();
      if (!isGuest) {
        // A guest on this device signed in to this account: its events
        // are the account's now, like its Play games.
        await _adoptGuestRows(db, targetUserId: userId);
      }
      final pending = await db.query(
        _table,
        where: 'synced = 0 AND (owner_user_id IS NULL OR owner_user_id = ?)',
        whereArgs: [userId],
        orderBy: 'updated_at ASC',
      );
      var uploaded = 0;
      for (var i = 0; i < pending.length; i += uploadBatchSize) {
        final batch = pending.skip(i).take(uploadBatchSize).toList();
        await _remote.upsert([
          for (final row in batch) playTournamentServerRow(row, userId: userId),
        ]);
        for (final row in batch) {
          // A newer local save of the same event stays pending.
          await db.update(
            _table,
            {
              'synced': 1,
              'owner_user_id': userId,
              'owner_is_guest': isGuest ? 1 : 0,
            },
            where: 'id = ? AND updated_at = ?',
            whereArgs: [row['id'], row['updated_at']],
          );
        }
        uploaded += batch.length;
      }
      return uploaded;
    } catch (e) {
      debugPrint('[PlayTournaments] server upload failed, kept local: $e');
      return 0;
    }
  }

  /// Hands the events uploaded for the guest [guestUserId] to
  /// [targetUserId] and queues them for upload under it. Called by the
  /// guest merger when the guest signs in to an account; the upload runs
  /// at once when [targetUserId] is signed in. Never throws.
  Future<void> adoptGuestEvents({
    required String guestUserId,
    required String targetUserId,
  }) async {
    if (guestUserId == targetUserId) return;
    try {
      final db = await _open();
      await _adoptGuestRows(
        db,
        targetUserId: targetUserId,
        guestUserId: guestUserId,
      );
    } catch (e) {
      debugPrint('[PlayTournaments] guest hand-over failed: $e');
      return;
    }
    if (_remote.currentUserId == targetUserId) await flushOutbox();
  }

  /// Moves guest-owned rows (all of them, or [guestUserId]'s) to
  /// [targetUserId], pending upload.
  Future<int> _adoptGuestRows(
    Database db, {
    required String targetUserId,
    String? guestUserId,
  }) {
    return db.update(
      _table,
      {'owner_user_id': targetUserId, 'owner_is_guest': 0, 'synced': 0},
      where:
          guestUserId == null
              ? 'owner_is_guest = 1 AND owner_user_id IS NOT NULL '
                  'AND owner_user_id != ?'
              : 'owner_user_id = ?',
      whereArgs: [guestUserId ?? targetUserId],
    );
  }

  /// Copies the signed-in account's server events that this device lacks
  /// (or holds an older uploaded copy of) into the local table. Reads the
  /// server a page at a time. Returns how many local rows changed; never
  /// throws.
  Future<int> mergeRemoteEvents() {
    return _merging ??= _merge().whenComplete(() => _merging = null);
  }

  Future<int> _merge() async {
    final userId = _remote.currentUserId;
    if (userId == null) return 0;
    try {
      final db = await _open();
      final localRows = await db.query(
        _table,
        columns: const ['id', 'updated_at', 'synced'],
      );
      final local = <String, ({int updatedAt, bool synced})>{
        for (final row in localRows)
          row['id'] as String: (
            updatedAt: row['updated_at'] as int,
            synced: row['synced'] == 1,
          ),
      };
      var changed = 0;
      for (var from = 0; ; from += mergePageSize) {
        final page = await _remote.fetchPage(
          userId: userId,
          from: from,
          to: from + mergePageSize - 1,
        );
        for (final remote in page) {
          final row = playTournamentLocalRowFromServer(remote, userId: userId);
          if (row == null) continue;
          final id = row['id'] as String;
          final mine = local[id];
          // Pending local edits win; they upload on the next flush.
          if (mine != null &&
              (!mine.synced || mine.updatedAt >= (row['updated_at'] as int))) {
            continue;
          }
          await db.insert(_table, {
            ...row,
            'owner_is_guest': _remote.currentUserIsAnonymous ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          local[id] = (updatedAt: row['updated_at'] as int, synced: true);
          changed++;
        }
        if (page.length < mergePageSize) break;
      }
      _mergedUserId = userId;
      _mergedAt = _clock();
      return changed;
    } catch (e) {
      debugPrint('[PlayTournaments] server merge failed: $e');
      return 0;
    }
  }

  /// Upload what is pending, then bring in what the server has. Run on app
  /// start with an account and on every sign-in.
  Future<void> syncNow() async {
    await flushOutbox();
    _mergedAt = null;
    await mergeRemoteEvents();
  }

  Future<void> _ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_table (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        format TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        completed_at INTEGER,
        participant_count INTEGER NOT NULL,
        game_count INTEGER NOT NULL,
        finished_game_count INTEGER NOT NULL,
        user_game_count INTEGER NOT NULL,
        user_finished_game_count INTEGER NOT NULL,
        user_score REAL NOT NULL,
        snapshot_json TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0,
        owner_user_id TEXT,
        owner_is_guest INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // Tables made before the server sync lack the outbox columns; their
    // events are pending (synced 0) and upload on the next sign-in.
    final columns = await db.rawQuery('PRAGMA table_info($_table)');
    final names = {
      for (final column in columns) column['name']?.toString().toLowerCase(),
    };
    if (!names.contains('synced')) {
      await db.execute(
        'ALTER TABLE $_table ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!names.contains('owner_user_id')) {
      await db.execute('ALTER TABLE $_table ADD COLUMN owner_user_id TEXT');
    }
    if (!names.contains('owner_is_guest')) {
      await db.execute(
        'ALTER TABLE $_table ADD COLUMN owner_is_guest INTEGER NOT NULL '
        'DEFAULT 0',
      );
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_${_table}_updated_at '
      'ON $_table (updated_at DESC)',
    );
  }

  PlayedTournamentEvent _eventFromRow(Map<String, Object?> row) {
    DateTime readDate(String key) {
      return DateTime.fromMillisecondsSinceEpoch(
        row[key] as int,
        isUtc: true,
      ).toLocal();
    }

    DateTime? readNullableDate(String key) {
      final value = row[key];
      if (value is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    }

    return PlayedTournamentEvent(
      id: row['id'] as String,
      title: row['title'] as String,
      format: TournamentFormat.values.firstWhere(
        (format) => format.name == row['format'],
        orElse: () => TournamentFormat.roundRobin,
      ),
      status: PlayedTournamentStatus.fromName(row['status'] as String),
      createdAt: readDate('created_at'),
      updatedAt: readDate('updated_at'),
      completedAt: readNullableDate('completed_at'),
      participantCount: row['participant_count'] as int,
      gameCount: row['game_count'] as int,
      finishedGameCount: row['finished_game_count'] as int,
      userGameCount: row['user_game_count'] as int,
      userFinishedGameCount: row['user_finished_game_count'] as int,
      userScore: (row['user_score'] as num).toDouble(),
    );
  }
}

String _isoOf(Object? millis) {
  return DateTime.fromMillisecondsSinceEpoch(
    millis as int,
    isUtc: true,
  ).toIso8601String();
}

int? _millisOf(Object? iso) {
  if (iso == null) return null;
  return DateTime.tryParse(iso.toString())?.toUtc().millisecondsSinceEpoch;
}

/// A number from a server row; PostgREST may send `numeric` as text.
num? _numOf(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

Map<String, Object?> _decodeSnapshot(Object? raw) {
  if (raw is Map) return Map<String, Object?>.from(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } catch (_) {}
  }
  return <String, Object?>{};
}

/// A local event row as its `user_play_tournaments` row for [userId].
///
/// `snapshot` carries the full event (participants, games, standings) plus a
/// `local` block with the counters this app's list shows, so another device
/// can rebuild the local row from the server row alone.
@visibleForTesting
Map<String, Object?> playTournamentServerRow(
  Map<String, Object?> row, {
  required String userId,
}) {
  final snapshot = _decodeSnapshot(row['snapshot_json']);
  final userScore = (row['user_score'] as num?)?.toDouble() ?? 0;
  final hasUser =
      snapshot['userParticipantId'] != null ||
      ((row['user_game_count'] as int?) ?? 0) > 0;
  final totalRounds = snapshot['totalRounds'];
  return {
    'user_id': userId,
    'local_event_key': row['id'],
    'title': row['title'],
    'format': row['format'],
    'status': row['status'],
    'started_at': _isoOf(row['created_at']),
    'finished_at':
        row['completed_at'] is int ? _isoOf(row['completed_at']) : null,
    'rounds': totalRounds is num ? totalRounds.toInt() : null,
    'players': row['participant_count'],
    'user_rank': (snapshot['userRank'] as num?)?.toInt(),
    'user_score': hasUser ? userScore : null,
    'snapshot': {
      ...snapshot,
      'local': {
        'participantCount': row['participant_count'],
        'gameCount': row['game_count'],
        'finishedGameCount': row['finished_game_count'],
        'userGameCount': row['user_game_count'],
        'userFinishedGameCount': row['user_finished_game_count'],
        'userScore': userScore,
        'createdAt': row['created_at'],
        'updatedAt': row['updated_at'],
        'completedAt': row['completed_at'],
      },
    },
    'updated_at': _isoOf(row['updated_at']),
  };
}

/// A `user_play_tournaments` row as a local event row owned by [userId], or
/// null when the row has no usable key. Rows written by other frontends may
/// lack the `local` block; the counters then come from the snapshot games.
@visibleForTesting
Map<String, Object?>? playTournamentLocalRowFromServer(
  Map<String, Object?> remote, {
  required String userId,
}) {
  final id = remote['local_event_key']?.toString() ?? '';
  if (id.isEmpty) return null;
  final snapshot = _decodeSnapshot(remote['snapshot']);
  final local = _decodeSnapshot(snapshot.remove('local'));
  final games =
      snapshot['games'] is List ? snapshot['games'] as List : const [];
  final participants =
      snapshot['participants'] is List
          ? snapshot['participants'] as List
          : const [];
  final userId0 = snapshot['userParticipantId']?.toString();

  int count(String key, int fallback) =>
      _numOf(local[key])?.toInt() ?? fallback;
  bool finished(Object? game) => game is Map && game['status'] == 'finished';
  bool isUserGame(Object? game) =>
      userId0 != null &&
      game is Map &&
      (game['whiteId'] == userId0 || game['blackId'] == userId0);

  final updatedAt =
      _numOf(local['updatedAt'])?.toInt() ??
      _millisOf(remote['updated_at']) ??
      DateTime.now().toUtc().millisecondsSinceEpoch;
  final createdAt =
      _numOf(local['createdAt'])?.toInt() ??
      _millisOf(remote['started_at']) ??
      updatedAt;
  final status = remote['status']?.toString() ?? '';
  return {
    'id': id,
    'title': remote['title']?.toString() ?? snapshot['title']?.toString() ?? '',
    'format':
        remote['format']?.toString() ??
        snapshot['format']?.toString() ??
        TournamentFormat.roundRobin.name,
    'status': PlayedTournamentStatus.fromName(status).name,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'completed_at':
        _numOf(local['completedAt'])?.toInt() ??
        _millisOf(remote['finished_at']),
    'participant_count': count(
      'participantCount',
      _numOf(remote['players'])?.toInt() ?? participants.length,
    ),
    'game_count': count('gameCount', games.length),
    'finished_game_count': count(
      'finishedGameCount',
      games.where(finished).length,
    ),
    'user_game_count': count('userGameCount', games.where(isUserGame).length),
    'user_finished_game_count': count(
      'userFinishedGameCount',
      games.where((g) => isUserGame(g) && finished(g)).length,
    ),
    'user_score':
        _numOf(local['userScore'])?.toDouble() ??
        _numOf(remote['user_score'])?.toDouble() ??
        0.0,
    'snapshot_json': jsonEncode(snapshot),
    'synced': 1,
    'owner_user_id': userId,
  };
}

/// The human's place in [snapshot]'s standings, 1 for the leader; tied
/// scores share a place. Null without a human in the event.
@visibleForTesting
int? playTournamentUserRank(TournamentSnapshot snapshot) {
  final humanId = snapshot.humanParticipantId;
  if (humanId == null) return null;
  TournamentStanding? mine;
  for (final standing in snapshot.standings) {
    if (standing.participantId == humanId) mine = standing;
  }
  if (mine == null) return null;
  final points = mine.points;
  return 1 + snapshot.standings.where((s) => s.points > points).length;
}

({
  int finishedGameCount,
  int userGameCount,
  int userFinishedGameCount,
  double userScore,
})
_summaryFor(TournamentSnapshot snapshot) {
  var finished = 0;
  var userGames = 0;
  var userFinished = 0;
  var userScore = 0.0;
  final humanId = snapshot.humanParticipantId;
  for (final game in snapshot.games) {
    final isFinished = game.status == TournamentGameStatus.finished;
    if (isFinished) finished++;
    final isUserGame =
        humanId != null && (game.whiteId == humanId || game.blackId == humanId);
    if (!isUserGame) continue;
    userGames++;
    if (!isFinished) continue;
    userFinished++;
    userScore += _scoreForHuman(game, humanId);
  }
  return (
    finishedGameCount: finished,
    userGameCount: userGames,
    userFinishedGameCount: userFinished,
    userScore: userScore,
  );
}

double _scoreForHuman(TournamentGame game, String humanId) {
  return switch (game.result) {
    '1-0' => game.whiteId == humanId ? 1.0 : 0.0,
    '0-1' => game.blackId == humanId ? 1.0 : 0.0,
    '1/2-1/2' => 0.5,
    _ => 0.0,
  };
}

Map<String, Object?> _snapshotToJson(TournamentSnapshot snapshot) {
  return {
    'id': snapshot.config.id,
    'title': snapshot.config.title,
    'format': snapshot.config.format.name,
    'status': snapshot.isRunning ? 'running' : 'stopped',
    'currentRound': snapshot.currentRound,
    'totalRounds': snapshot.totalRounds,
    'baseSeconds': snapshot.config.baseSeconds,
    'incrementSeconds': snapshot.config.incrementSeconds,
    'userParticipantId': snapshot.humanParticipantId,
    'userRank': playTournamentUserRank(snapshot),
    'standings': [
      for (final standing in snapshot.standings)
        {
          'participantId': standing.participantId,
          'points': standing.points,
          'played': standing.played,
        },
    ],
    'participants': [
      for (final participant in snapshot.config.participants)
        {
          'id': participant.id,
          'name': participant.identity.fullName,
          'displayName': participant.identity.displayName,
          'country': participant.identity.countryCode,
          'elo': participant.identity.elo,
          'title': participant.identity.title,
          'engine': participant.engine.name,
          'human': participant.isHuman,
        },
    ],
    'games': [
      for (final game in snapshot.games)
        {
          'id': game.id,
          'round': game.round,
          'whiteId': game.whiteId,
          'blackId': game.blackId,
          'status': game.status.name,
          'result': game.result,
          'fen': game.fen,
          'movesUci': game.movesUci,
          'endReason': game.endReason,
          'ecoLine': game.ecoLine,
        },
    ],
  };
}

final playTournamentHistoryRepositoryProvider =
    Provider<PlayTournamentHistoryRepository>((ref) {
      return PlayTournamentHistoryRepository(ref.watch(appDatabaseProvider));
    });

/// How long after launch the first upload and merge wait, so they stay out
/// of the first frames.
const Duration kPlayTournamentSyncLaunchDelay = Duration(seconds: 10);

/// Keeps played events in step with the server: uploads the outbox and
/// merges the account's server events on launch with an account and on
/// every sign-in or account switch. Watched by the shell, main window only
/// (a detached board window must not race the main window's uploads).
final playTournamentCloudSyncProvider = Provider<void>((ref) {
  if (ref.watch(desktopWindowRoleProvider) != DesktopWindowRole.main) return;
  if (!DesktopSupabaseInit.isInitialized) return;
  final auth = Supabase.instance.client.auth;
  final repository = ref.watch(playTournamentHistoryRepositoryProvider);
  String? syncedUserId;
  void syncFor(String? userId) {
    if (userId == null || userId == syncedUserId) return;
    syncedUserId = userId;
    unawaited(
      repository.syncNow().then((_) {
        ref.invalidate(playedTournamentEventsProvider);
      }),
    );
  }

  final launch = Timer(
    kPlayTournamentSyncLaunchDelay,
    () => syncFor(auth.currentUser?.id),
  );
  final sub = auth.onAuthStateChange.listen((event) {
    final userId = event.session?.user.id;
    if (userId == null) {
      syncedUserId = null;
      return;
    }
    if (launch.isActive) return;
    syncFor(userId);
  }, onError: (Object e) => debugPrint('[PlayTournaments] auth event: $e'));
  ref.onDispose(() {
    launch.cancel();
    unawaited(sub.cancel());
  });
});

final playedTournamentEventsProvider =
    FutureProvider.autoDispose<List<PlayedTournamentEvent>>((ref) {
      return ref.watch(playTournamentHistoryRepositoryProvider).fetchEvents();
    });

Future<void> saveTournamentEventSnapshot(
  WidgetRef ref,
  TournamentSnapshot snapshot, {
  PlayedTournamentStatus? statusOverride,
}) async {
  final inferredStatus =
      snapshot.games.isNotEmpty &&
              snapshot.games.every(
                (game) => game.status == TournamentGameStatus.finished,
              )
          ? PlayedTournamentStatus.completed
          : snapshot.isRunning
          ? PlayedTournamentStatus.running
          : PlayedTournamentStatus.stopped;
  final status = statusOverride ?? inferredStatus;
  await ref
      .read(playTournamentHistoryRepositoryProvider)
      .upsertSnapshot(snapshot, status: status);
  ref.invalidate(playedTournamentEventsProvider);
}
