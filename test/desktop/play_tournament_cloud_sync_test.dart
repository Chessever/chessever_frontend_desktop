import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_tournament_history_repository.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';

class _FakeRemote implements PlayTournamentRemote {
  @override
  String? currentUserId;

  @override
  bool currentUserIsAnonymous = false;

  final Map<String, Map<String, Object?>> rows = {};
  final List<int> upsertBatchSizes = [];
  final List<(int, int)> pages = [];
  bool failUpserts = false;

  @override
  Future<void> upsert(List<Map<String, Object?>> batch) async {
    if (failUpserts) throw Exception('offline');
    upsertBatchSizes.add(batch.length);
    for (final row in batch) {
      rows['${row['user_id']}|${row['local_event_key']}'] = row;
    }
  }

  @override
  Future<List<Map<String, Object?>>> fetchPage({
    required String userId,
    required int from,
    required int to,
  }) async {
    pages.add((from, to));
    final mine =
        rows.values.where((row) => row['user_id'] == userId).toList()..sort(
          (a, b) =>
              (b['updated_at'] as String).compareTo(a['updated_at'] as String),
        );
    if (from >= mine.length) return const [];
    return mine.sublist(from, (to + 1).clamp(0, mine.length));
  }
}

TournamentParticipant _participant(String id, {bool human = false}) {
  return TournamentParticipant(
    id: id,
    identity: BotIdentity(
      firstName: id,
      lastName: 'Test',
      countryCode: 'NO',
      elo: 1500,
    ),
    engine: BotEngineKind.stockfish,
    isHuman: human,
  );
}

TournamentSnapshot _snapshot({
  String id = 'event-1',
  bool running = false,
  List<TournamentStanding>? standings,
}) {
  return TournamentSnapshot(
    config: TournamentConfig(
      id: id,
      title: 'Friday Arena',
      format: TournamentFormat.roundRobin,
      baseSeconds: 180,
      incrementSeconds: 2,
      participants: [
        _participant('me', human: true),
        _participant('a'),
        _participant('b'),
      ],
    ),
    games: const [
      TournamentGame(
        id: 'g1',
        round: 1,
        whiteId: 'me',
        blackId: 'a',
        status: TournamentGameStatus.finished,
        result: '1-0',
        movesUci: ['e2e4'],
      ),
      TournamentGame(
        id: 'g2',
        round: 2,
        whiteId: 'b',
        blackId: 'me',
        status: TournamentGameStatus.finished,
        result: '1/2-1/2',
      ),
      TournamentGame(
        id: 'g3',
        round: 3,
        whiteId: 'a',
        blackId: 'b',
        status: TournamentGameStatus.inProgress,
      ),
    ],
    standings:
        standings ??
        const [
          TournamentStanding(participantId: 'b', points: 1.5, played: 2),
          TournamentStanding(participantId: 'me', points: 1.5, played: 2),
          TournamentStanding(participantId: 'a', points: 0, played: 2),
        ],
    currentRound: 3,
    totalRounds: 3,
    isRunning: running,
    resourceAssessment: const TournamentResourceAssessment(
      level: TournamentResourceWarningLevel.ok,
      hostCores: 8,
      recommendedConcurrency: 2,
      recommendedMaxParticipants: 8,
      message: 'ok',
    ),
  );
}

void main() {
  late Database db;
  late _FakeRemote remote;
  late DateTime now;
  late PlayTournamentHistoryRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
    remote = _FakeRemote();
    now = DateTime.utc(2026, 11, 27, 12);
    repository = PlayTournamentHistoryRepository.withOpener(
      () async => db,
      remote: remote,
      clock: () => now,
    );
  });

  tearDown(() => db.close());

  test('rank is shared by tied scores and null without a human', () {
    expect(playTournamentUserRank(_snapshot()), 1);
    expect(
      playTournamentUserRank(
        _snapshot(
          standings: const [
            TournamentStanding(participantId: 'a', points: 2, played: 2),
            TournamentStanding(participantId: 'b', points: 2, played: 2),
            TournamentStanding(participantId: 'me', points: 1, played: 2),
          ],
        ),
      ),
      3,
    );
  });

  test('a saved event maps onto every server column', () async {
    remote.currentUserId = 'user-1';
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.completed,
      awaitUpload: true,
    );

    final row = remote.rows['user-1|event-1']!;
    expect(row['user_id'], 'user-1');
    expect(row['title'], 'Friday Arena');
    expect(row['format'], 'roundRobin');
    expect(row['status'], 'completed');
    expect(row['started_at'], '2026-11-27T12:00:00.000Z');
    expect(row['finished_at'], '2026-11-27T12:00:00.000Z');
    expect(row['updated_at'], '2026-11-27T12:00:00.000Z');
    expect(row['rounds'], 3);
    expect(row['players'], 3);
    expect(row['user_rank'], 1);
    expect(row['user_score'], 1.5);
    final snapshot = row['snapshot']! as Map<String, Object?>;
    expect((snapshot['games']! as List).length, 3);
    expect((snapshot['standings']! as List).length, 3);
    expect(snapshot['userParticipantId'], 'me');
    expect((snapshot['local']! as Map)['userFinishedGameCount'], 2);
    expect(jsonEncode(row), isNotEmpty, reason: 'row must be JSON-safe');

    final local = await db.query('desktop_play_tournament_events');
    expect(local.single['synced'], 1);
    expect(local.single['owner_user_id'], 'user-1');
  });

  test('a running event uploads with no finish time', () async {
    remote.currentUserId = 'user-1';
    await repository.upsertSnapshot(
      _snapshot(running: true),
      status: PlayedTournamentStatus.running,
      awaitUpload: true,
    );
    final row = remote.rows['user-1|event-1']!;
    expect(row['status'], 'running');
    expect(row['finished_at'], isNull);
  });

  test('events saved signed out or offline upload later', () async {
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.completed,
      awaitUpload: true,
    );
    expect(remote.rows, isEmpty);

    remote
      ..currentUserId = 'user-1'
      ..failUpserts = true;
    now = now.add(const Duration(minutes: 1));
    await repository.upsertSnapshot(
      _snapshot(id: 'event-2'),
      status: PlayedTournamentStatus.stopped,
      awaitUpload: true,
    );
    expect(remote.rows, isEmpty);
    final pending = await db.query(
      'desktop_play_tournament_events',
      where: 'synced = 0',
    );
    expect(pending, hasLength(2));

    remote.failUpserts = false;
    expect(await repository.flushOutbox(), 2);
    expect(remote.rows.keys, {'user-1|event-1', 'user-1|event-2'});
    expect(await repository.flushOutbox(), 0);
  });

  test('an event uploaded for one account stays with it', () async {
    remote.currentUserId = 'user-1';
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.completed,
      awaitUpload: true,
    );
    remote.currentUserId = 'user-2';
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.completed,
      awaitUpload: true,
    );
    expect(remote.rows.keys, {'user-1|event-1'});
  });

  test('a guest\'s events move to the account it signs in to', () async {
    remote
      ..currentUserId = 'guest'
      ..currentUserIsAnonymous = true;
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.completed,
      awaitUpload: true,
    );
    expect(remote.rows.keys, {'guest|event-1'});

    remote
      ..currentUserId = 'account'
      ..currentUserIsAnonymous = false;
    expect(await repository.flushOutbox(), 1);
    expect(remote.rows.keys, containsAll(['guest|event-1', 'account|event-1']));
    final local = await db.query('desktop_play_tournament_events');
    expect(local.single['owner_user_id'], 'account');
    expect(local.single['owner_is_guest'], 0);
    expect(local.single['synced'], 1);

    // A later account never takes the permanent account's events.
    remote.currentUserId = 'other';
    expect(await repository.flushOutbox(), 0);
    expect(remote.rows.keys.where((k) => k.startsWith('other|')), isEmpty);
  });

  test('the guest merger hands events over by guest id', () async {
    // Uploaded for the guest before the owner flag existed.
    remote.currentUserId = 'guest';
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.completed,
      awaitUpload: true,
    );
    await db.update('desktop_play_tournament_events', {'owner_is_guest': 0});

    remote.currentUserId = 'account';
    await repository.adoptGuestEvents(
      guestUserId: 'guest',
      targetUserId: 'account',
    );
    expect(remote.rows.keys, contains('account|event-1'));
    final local = await db.query('desktop_play_tournament_events');
    expect(local.single['owner_user_id'], 'account');
    expect(local.single['synced'], 1);
  });

  test('server events missing here are merged across pages', () async {
    final source = PlayTournamentHistoryRepository.withOpener(
      () async => db,
      remote: remote,
      clock: () => now,
    );
    remote.currentUserId = 'user-1';
    final total = PlayTournamentHistoryRepository.mergePageSize + 5;
    for (var i = 0; i < total; i++) {
      now = now.add(const Duration(seconds: 1));
      await source.upsertSnapshot(
        _snapshot(id: 'event-$i'),
        status: PlayedTournamentStatus.completed,
      );
    }
    await source.flushOutbox();
    expect(remote.rows, hasLength(total));

    // A fresh device: empty table, same account.
    final other = await databaseFactoryFfiNoIsolate.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(other.close);
    remote.pages.clear();
    final device = PlayTournamentHistoryRepository.withOpener(
      () async => other,
      remote: remote,
      clock: () => now,
    );
    final events = await device.fetchEvents(limit: 500);
    expect(events, hasLength(total));
    expect(remote.pages.length, 2);
    final merged = events.firstWhere((e) => e.id == 'event-0');
    expect(merged.title, 'Friday Arena');
    expect(merged.status, PlayedTournamentStatus.completed);
    expect(merged.participantCount, 3);
    expect(merged.gameCount, 3);
    expect(merged.finishedGameCount, 2);
    expect(merged.userGameCount, 2);
    expect(merged.userFinishedGameCount, 2);
    expect(merged.userScore, 1.5);
    expect(merged.completedAt, isNotNull);

    // Merged rows are not uploaded back, and a fresh merge is not repeated.
    expect(await device.flushOutbox(), 0);
    remote.pages.clear();
    await device.fetchEvents();
    expect(remote.pages, isEmpty);
  });

  test('a pending local edit is not overwritten by the server copy', () async {
    remote.currentUserId = 'user-1';
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.completed,
      awaitUpload: true,
    );
    remote.failUpserts = true;
    now = now.add(const Duration(minutes: 1));
    await repository.upsertSnapshot(
      _snapshot(),
      status: PlayedTournamentStatus.aborted,
      awaitUpload: true,
    );
    await repository.syncNow();
    final events = await repository.fetchEvents();
    expect(events.single.status, PlayedTournamentStatus.aborted);
  });

  test('a row from another frontend without local counters reads', () {
    final row =
        playTournamentLocalRowFromServer({
          'local_event_key': 'web-1',
          'title': 'Web Cup',
          'format': 'knockout',
          'status': 'completed',
          'started_at': '2026-11-01T10:00:00Z',
          'finished_at': '2026-11-01T11:00:00Z',
          'players': 4,
          'user_score': '2.5',
          'updated_at': '2026-11-01T11:00:00Z',
          'snapshot': {
            'userParticipantId': 'me',
            'games': [
              {'whiteId': 'me', 'blackId': 'x', 'status': 'finished'},
              {'whiteId': 'y', 'blackId': 'me', 'status': 'scheduled'},
              {'whiteId': 'y', 'blackId': 'x', 'status': 'finished'},
            ],
          },
        }, userId: 'user-1')!;
    expect(row['id'], 'web-1');
    expect(row['format'], 'knockout');
    expect(row['participant_count'], 4);
    expect(row['game_count'], 3);
    expect(row['finished_game_count'], 2);
    expect(row['user_game_count'], 2);
    expect(row['user_finished_game_count'], 1);
    expect(row['user_score'], 2.5);
    expect(
      row['created_at'],
      DateTime.utc(2026, 11, 1, 10).millisecondsSinceEpoch,
    );
    expect(
      row['completed_at'],
      DateTime.utc(2026, 11, 1, 11).millisecondsSinceEpoch,
    );
    expect(row['synced'], 1);
    expect(
      playTournamentLocalRowFromServer({'title': 'x'}, userId: 'u'),
      isNull,
    );
  });

  test('a table from before the sync gains the outbox columns', () async {
    await db.execute('''
      CREATE TABLE desktop_play_tournament_events (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, format TEXT NOT NULL,
        status TEXT NOT NULL, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, completed_at INTEGER,
        participant_count INTEGER NOT NULL, game_count INTEGER NOT NULL,
        finished_game_count INTEGER NOT NULL, user_game_count INTEGER NOT NULL,
        user_finished_game_count INTEGER NOT NULL, user_score REAL NOT NULL,
        snapshot_json TEXT NOT NULL
      )
    ''');
    await db.insert('desktop_play_tournament_events', {
      'id': 'old',
      'title': 'Old Cup',
      'format': 'roundRobin',
      'status': 'completed',
      'created_at': 1,
      'updated_at': 2,
      'participant_count': 2,
      'game_count': 1,
      'finished_game_count': 1,
      'user_game_count': 1,
      'user_finished_game_count': 1,
      'user_score': 1.0,
      'snapshot_json': jsonEncode({'totalRounds': 1}),
    });
    remote.currentUserId = 'user-1';
    expect(await repository.flushOutbox(), 1);
    expect(remote.rows['user-1|old']!['rounds'], 1);
  });
}
