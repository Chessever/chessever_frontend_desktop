import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:chessever/web/shims/local_sqlite.dart' as localsql;

import 'package:chessever/desktop/models/player_download_preferences.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/services/prep_cloud_sync.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/state/prep_profiles_cloud.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';

// The desktop side of Prep sync: Players workspace profiles as rows, and
// rows (as the mobile app writes them) as profiles here, against an
// in-memory server. The rules themselves are in prep_cloud_sync_test.dart.

class _Server implements PrepCloudRemote {
  final rows = <String, PrepCloudRow>{};

  @override
  Future<List<PrepCloudRow>?> fetch() async => rows.values.toList();

  @override
  Future<bool> write(
    String id,
    PrepJson profile, {
    required bool deleted,
  }) async {
    rows[id] = PrepCloudRow(
      id: id,
      profile: jsonDecode(jsonEncode(profile)) as PrepJson,
      deleted: deleted,
    );
    return true;
  }
}

class _Repository extends PlayerWorkspaceRepository {
  _Repository({required this.root, required this.snapshot})
    : super(supportDirectory: () async => root);

  final Directory root;
  PlayerWorkspaceSnapshot snapshot;

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }

  @override
  Future<bool> isCombinedDatabaseCurrent(String path) async => true;

  @override
  Future<bool> deleteSourcePgnFile(String path) async => false;

  @override
  Future<bool> deletePlayerWorkspaceDirectory(String playerId) async => false;
}

class _Pointer extends MyPrepProfileStore {
  _Pointer(this.id);
  String? id;

  @override
  Future<String?> read() async => id;

  @override
  Future<void> write(String? playerId) async => id = playerId;
}

/// A row as the mobile app writes one.
PrepJson _mobileRow(
  String name,
  List<PrepJson> accounts, {
  String kind = 'opponent',
}) => <String, dynamic>{
  'name': name,
  'kind': kind,
  'createdAtMs': 1700000000000,
  'accounts': accounts,
};

PrepJson _mobileAccount(
  String source,
  String username, {
  String range = 'year',
  List<String> clocks = const <String>['blitz', 'rapid'],
  String? externalId,
}) => <String, dynamic>{
  'source': source,
  'username': username,
  if (externalId != null) 'externalId': externalId,
  'playerAliases': <String>[username],
  'preferences': <String, dynamic>{
    'timeControls': clocks,
    'range': range,
    'fromDate': null,
    'toDate': null,
  },
};

PlayerWorkspacePlayer _player(
  String id,
  String name,
  List<PlayerWorkspaceAccount> accounts,
) {
  var player = PlayerWorkspacePlayer(id: id, displayName: name, createdAtMs: 5);
  for (final account in accounts) {
    player = player.withAccount(account);
  }
  return player;
}

const _lichess = PlayerWorkspaceAccount(
  source: PlayerWorkspaceSource.lichess,
  username: 'YagizKaan',
);
const _chesscom = PlayerWorkspaceAccount(
  source: PlayerWorkspaceSource.chesscom,
  username: 'yagiz',
);

void main() {
  late Directory temp;
  late localsql.Database db;
  late _Server server;
  late _Repository repository;
  late _Pointer pointer;
  late ProviderContainer container;
  var started = false;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever-prep-cloud-');
    db = await localsql.Database.open(p.join(temp.path, 'local_chess.db'));
    await createLocalChessCacheDatabaseSchema(db);
    server = _Server();
  });

  tearDown(() async {
    if (started) {
      await container
          .read(playerWorkspaceProvider.notifier)
          .debugDrainPlayerCleanup();
      container.dispose();
      started = false;
    }
    await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// Past the two seconds a change here waits before it is written.
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await container
        .read(playerWorkspaceProvider.notifier)
        .debugDrainPlayerCleanup();
  }

  /// This desktop, holding [players], signed in as [user].
  Future<void> desktop({
    List<PlayerWorkspacePlayer> players = const <PlayerWorkspacePlayer>[],
    String? own,
    String? user = 'reader',
  }) async {
    repository = _Repository(
      root: temp,
      snapshot: PlayerWorkspaceSnapshot(players: players),
    );
    pointer = _Pointer(own);
    // What the sync remembers outlives a look, as it outlives a restart.
    final remembered = PrepCloudStore.inMemory();
    started = true;
    container = ProviderContainer(
      overrides: [
        playerWorkspaceProvider.overrideWith(
          (ref) => PlayerWorkspaceNotifier(
            workspaceRepository: repository,
            gamebaseRepository: GamebaseRepository(Dio()),
            localRepository: LocalChessDatabaseRepository(
              database: () async => db,
            ),
          ),
        ),
        myPrepProfileStoreProvider.overrideWithValue(pointer),
        prepCloudUserProvider.overrideWithValue(user),
        prepCloudRemoteProvider.overrideWith((ref, _) => server),
        prepCloudStoreProvider.overrideWithValue(() async => remembered),
        prepCloudLaunchDelayProvider.overrideWithValue(Duration.zero),
      ],
    );
    container.listen(prepCloudSyncProvider, (_, __) {});
    await settle();
  }

  /// Another device changed the server; the next look comes round.
  Future<void> look() async {
    // A no-op edit here does not start a write: the look is asked for
    // through a change the sync notices and then finds nothing to send.
    container.invalidate(prepCloudSyncProvider);
    container.listen(prepCloudSyncProvider, (_, __) {});
    await settle();
  }

  List<PlayerWorkspacePlayer> held() =>
      container.read(playerWorkspaceProvider).players;
  PlayerWorkspaceNotifier workspace() =>
      container.read(playerWorkspaceProvider.notifier);

  test('a row this app writes holds who the player is and the sources '
      'another device can download, never files', () {
    final player = _player('player-5-yagiz', 'Yagiz', <PlayerWorkspaceAccount>[
      _lichess.copyWith(
        gameCount: 158,
        pgnPath: '/tmp/a.pgn',
        downloadPreferences: PlayerDownloadPreferences(
          timeControls: const <PlayerDownloadTimeControl>{
            PlayerDownloadTimeControl.blitz,
          },
          fromDate: DateTime.utc(2025, 1, 1),
        ),
      ),
      const PlayerWorkspaceAccount(
        source: PlayerWorkspaceSource.manual,
        username: 'club.pgn',
        pgnPath: '/tmp/club.pgn',
      ),
    ]);
    final row = prepCloudProfile(player, own: true);
    expect(row['name'], 'Yagiz');
    expect(row['kind'], 'mine');
    final account = (row['accounts'] as List).single as Map;
    expect(account['source'], 'lichess');
    expect(account['username'], 'YagizKaan');
    expect(account.containsKey('pgnPath'), isFalse);
    expect(account['preferences'], <String, dynamic>{
      'timeControls': <String>['blitz'],
      'range': 'custom',
      'fromDate': '2025-01-01',
      'toDate': null,
    });
    expect(prepCloudProfile(player, own: false)['kind'], 'opponent');
  });

  test('a row the mobile app wrote reads as a player with its sources '
      'connected and nothing downloaded', () {
    final player =
        prepCloudPlayer('opponent-1700000000000-0', <String, dynamic>{
          ..._mobileRow('Magnus Carlsen', <PrepJson>[
            _mobileAccount('lichess', 'DrNykterstein', range: 'months3'),
            _mobileAccount(
              'chessever',
              'Carlsen, Magnus',
              externalId: 'gb-1',
              range: 'all',
            ),
          ]),
          'fideIdentity': '1503014',
        })!;
    expect(player.id, 'opponent-1700000000000-0');
    expect(player.displayName, 'Magnus Carlsen');
    expect(player.fideId, '1503014');
    expect(player.chesseverPlayerId, 'gb-1');
    final lichess = player.account(PlayerWorkspaceSource.lichess)!;
    expect(lichess.username, 'DrNykterstein');
    expect(lichess.gameCount, 0);
    expect(lichess.pgnPath, isNull);
    // A rolling range has no counterpart here: all dates.
    expect(lichess.downloadPreferences.fromDate, isNull);
    expect(
      lichess.downloadPreferences.timeControls,
      <PlayerDownloadTimeControl>{
        PlayerDownloadTimeControl.blitz,
        PlayerDownloadTimeControl.rapid,
      },
    );
    expect(player.account(PlayerWorkspaceSource.chessever)!.externalId, 'gb-1');
  });

  test('a row with no source this app can hold is not a player', () {
    expect(prepCloudPlayer('x', _mobileRow('Nobody', <PrepJson>[])), isNull);
    expect(
      prepCloudPlayer('x', <String, dynamic>{'accounts': <PrepJson>[]}),
      isNull,
    );
  });

  test('the players already here are written, the reader\'s own as their '
      'own', () async {
    await desktop(
      players: <PlayerWorkspacePlayer>[
        _player('player-5-yagiz', 'Yagiz', <PlayerWorkspaceAccount>[_lichess]),
        _player('player-6-me', 'Me', <PlayerWorkspaceAccount>[_chesscom]),
      ],
      own: 'player-6-me',
    );
    expect(server.rows.keys.toSet(), <String>{'player-5-yagiz', 'player-6-me'});
    expect(server.rows['player-5-yagiz']!.profile['kind'], 'opponent');
    expect(server.rows['player-6-me']!.profile['kind'], 'mine');
    // Nothing here changed.
    expect(held().map((player) => player.id).toSet(), <String>{
      'player-5-yagiz',
      'player-6-me',
    });
  });

  test('a profile made in the mobile app appears here, and its own profile '
      'becomes My Prep', () async {
    server.rows['opponent-1-0'] = PrepCloudRow(
      id: 'opponent-1-0',
      profile: _mobileRow('Hikaru Nakamura', <PrepJson>[
        _mobileAccount('chesscom', 'Hikaru'),
      ]),
    );
    server.rows['mine-2-0'] = PrepCloudRow(
      id: 'mine-2-0',
      profile: _mobileRow('Me', <PrepJson>[
        _mobileAccount('lichess', 'me_li'),
      ], kind: 'mine'),
    );
    await desktop();
    expect(held().map((player) => player.id).toSet(), <String>{
      'opponent-1-0',
      'mine-2-0',
    });
    final hikaru = held().firstWhere((player) => player.id == 'opponent-1-0');
    expect(hikaru.displayName, 'Hikaru Nakamura');
    expect(hikaru.account(PlayerWorkspaceSource.chesscom)!.username, 'Hikaru');
    expect(hikaru.account(PlayerWorkspaceSource.chesscom)!.gameCount, 0);
    expect(pointer.id, 'mine-2-0');
    // It is saved with the roster.
    expect(repository.snapshot.players, hasLength(2));
  });

  test('a source added, changed and removed in the mobile app follows here; '
      'the phone\'s rolling range is never rewritten', () async {
    server.rows['opponent-1-0'] = PrepCloudRow(
      id: 'opponent-1-0',
      profile: _mobileRow('Yagiz', <PrepJson>[
        _mobileAccount('lichess', 'YagizKaan', range: 'months3'),
        _mobileAccount('chesscom', 'yagiz'),
      ]),
    );
    await desktop();
    expect(held().single.allAccounts, hasLength(2));

    // On the phone: Chess.com removed, Lichess narrowed, renamed.
    server.rows['opponent-1-0'] = PrepCloudRow(
      id: 'opponent-1-0',
      profile: _mobileRow('Yagiz Kaan Erdogmus', <PrepJson>[
        _mobileAccount(
          'lichess',
          'YagizKaan',
          range: 'months3',
          clocks: <String>['classical'],
        ),
      ]),
    );
    await look();
    final player = held().single;
    expect(player.displayName, 'Yagiz Kaan Erdogmus');
    expect(player.allAccounts.single.source, PlayerWorkspaceSource.lichess);
    expect(
      player.allAccounts.single.downloadPreferences.timeControls,
      <PlayerDownloadTimeControl>{PlayerDownloadTimeControl.classical},
    );

    // The reader renames it here: the row keeps the phone's range.
    await workspace().renamePlayer('opponent-1-0', 'Yagiz K.');
    await settle();
    final row = server.rows['opponent-1-0']!.profile;
    expect(row['name'], 'Yagiz K.');
    final account = (row['accounts'] as List).single as Map;
    expect(account['preferences']['range'], 'months3');
    expect(account['playerAliases'], <String>['YagizKaan']);
  });

  test('a profile deleted in the mobile app is removed here; one holding '
      'PGN files stays', () async {
    await desktop(
      players: <PlayerWorkspacePlayer>[
        _player('player-5-yagiz', 'Yagiz', <PlayerWorkspaceAccount>[_lichess]),
        _player('player-6-club', 'Club', <PlayerWorkspaceAccount>[
          _chesscom,
          const PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.manual,
            username: 'club.pgn',
          ),
        ]),
      ],
    );
    for (final id in <String>['player-5-yagiz', 'player-6-club']) {
      server.rows[id] = PrepCloudRow(
        id: id,
        profile: server.rows[id]!.profile,
        deleted: true,
      );
    }
    await look();
    expect(held().map((player) => player.id), <String>['player-6-club']);
    expect(held().single.allAccounts, hasLength(2));
  });

  test('deleting a player here marks its row deleted, and it is not '
      'brought back', () async {
    await desktop(
      players: <PlayerWorkspacePlayer>[
        _player('player-5-yagiz', 'Yagiz', <PlayerWorkspaceAccount>[_lichess]),
      ],
    );
    await workspace().removePlayer('player-5-yagiz');
    await settle();
    expect(server.rows['player-5-yagiz']!.deleted, isTrue);
    await look();
    expect(held(), isEmpty);
  });

  test(
    'signed out, or in a board window, nothing is read or written',
    () async {
      await desktop(
        players: <PlayerWorkspacePlayer>[
          _player('player-5-yagiz', 'Yagiz', <PlayerWorkspaceAccount>[
            _lichess,
          ]),
        ],
        user: null,
      );
      expect(server.rows, isEmpty);
      expect(held().single.id, 'player-5-yagiz');
    },
  );
}
