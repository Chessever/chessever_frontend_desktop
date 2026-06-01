import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
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

class PlayTournamentHistoryRepository {
  PlayTournamentHistoryRepository(this._db);

  final AppDatabase _db;

  static const String _table = 'desktop_play_tournament_events';

  Future<void> upsertSnapshot(
    TournamentSnapshot snapshot, {
    required PlayedTournamentStatus status,
  }) async {
    final db = await _db.database;
    await _ensureTable(db);
    final now = DateTime.now().toUtc();
    final existing = await db.query(
      _table,
      columns: const ['created_at'],
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
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PlayedTournamentEvent>> fetchEvents({int limit = 120}) async {
    final db = await _db.database;
    await _ensureTable(db);
    final rows = await db.query(
      _table,
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(_eventFromRow).toList(growable: false);
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
        snapshot_json TEXT NOT NULL
      )
    ''');
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
