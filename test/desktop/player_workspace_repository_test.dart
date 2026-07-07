import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_stats_repository.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';

void main() {
  late resqlite.Database db;
  late Directory temp;

  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever-player-workspace-');
    db = await resqlite.Database.open('${temp.path}/local_chess.db');
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('PRAGMA journal_mode=WAL');
    await createLocalChessResqliteDatabaseSchema(db);
  });

  tearDown(() async {
    await db.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  group('Player workspace PGN helpers', () {
    test('splits multi-game PGN exports by Event header', () {
      final games = splitPgnGames('''
[Event "Rated blitz game"]
[Site "https://lichess.org/abc"]
[White "MagnusCarlsen"]
[Black "Hikaru"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0

[Event "Live Chess"]
[Site "Chess.com"]
[White "Hikaru"]
[Black "MagnusCarlsen"]
[Result "0-1"]

1. d4 Nf6 2. c4 e6 0-1
''');

      expect(games, hasLength(2));
      expect(games.first, contains('Rated blitz game'));
      expect(games.last, contains('Live Chess'));
    });

    test('computes player-perspective win draw loss stats', () {
      final stats = analyzePgnStats(
        splitPgnGames('''
[Event "A"]
[White "Carlsen, Magnus"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5 1-0

[Event "B"]
[White "Opponent"]
[Black "Magnus Carlsen"]
[Result "1-0"]

1. d4 d5 1-0

[Event "C"]
[White "Magnus Carlsen"]
[Black "Opponent"]
[Result "1/2-1/2"]

1. c4 c5 1/2-1/2
'''),
        const <String>['Magnus Carlsen', 'Carlsen, Magnus'],
      );

      expect(stats.gameCount, 3);
      expect(stats.winCount, 1);
      expect(stats.drawCount, 1);
      expect(stats.lossCount, 1);
    });
  });

  group('Player workspace model persistence', () {
    test('snapshot round-trips selected player and connected accounts', () {
      final snapshot = PlayerWorkspaceSnapshot(
        selectedPlayerId: 'p1',
        players: const [
          PlayerWorkspacePlayer(
            id: 'p1',
            displayName: 'Magnus Carlsen',
            createdAtMs: 123,
            country: 'NOR',
            accounts: {
              PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.lichess,
                username: 'DrNykterstein',
                displayName: 'DrNykterstein',
                availableGameCount: 20,
                gameCount: 12,
                winCount: 7,
                drawCount: 2,
                lossCount: 3,
                ratings: {'Blitz': 3200},
              ),
            },
            combinedGameCount: 10,
            combinedWinCount: 6,
            combinedDrawCount: 2,
            combinedLossCount: 2,
          ),
        ],
      );

      final restored = PlayerWorkspaceSnapshot.fromJson(snapshot.toJson());

      expect(restored.selectedPlayerId, 'p1');
      expect(restored.players, hasLength(1));
      final player = restored.players.single;
      expect(player.displayName, 'Magnus Carlsen');
      expect(player.totalGames, 10);
      expect(player.winRate, closeTo(0.6, 0.001));
      final lichess = player.account(PlayerWorkspaceSource.lichess);
      expect(lichess?.username, 'DrNykterstein');
      expect(lichess?.availableGameCount, 20);
      expect(lichess?.gameCount, 12);
      expect(lichess?.remainingGameCount, 8);
      expect(lichess?.ratings['Blitz'], 3200);
    });

    test('migrates legacy profile-only game counts to available games', () {
      final account = PlayerWorkspaceAccount.fromJson(const {
        'source': 'lichess',
        'username': 'DrNykterstein',
        'gameCount': 48,
      });

      expect(account, isNotNull);
      expect(account!.availableGameCount, 48);
      expect(account.gameCount, 0);
      expect(account.hasDownloadedGames, isFalse);
      expect(account.downloadProgress, 0.0);
    });

    test('removing a source account clears stale combined database state', () {
      const player = PlayerWorkspacePlayer(
        id: 'p1',
        displayName: 'Magnus Carlsen',
        createdAtMs: 123,
        chesseverPlayerId: 'ce1',
        accounts: {
          PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chessever,
            username: 'Magnus Carlsen',
            externalId: 'ce1',
            gameCount: 20,
          ),
          PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'DrNykterstein',
            gameCount: 10,
          ),
        },
        combinedPgnPath: '/tmp/combined.pgn',
        combinedGameCount: 25,
        combinedWinCount: 12,
        combinedDrawCount: 5,
        combinedLossCount: 8,
        combinedBuiltAtMs: 456,
      );

      final updated = player.withoutAccount(PlayerWorkspaceSource.lichess);

      expect(updated.account(PlayerWorkspaceSource.lichess), isNull);
      expect(updated.account(PlayerWorkspaceSource.chessever), isNotNull);
      expect(updated.combinedPgnPath, isNull);
      expect(updated.combinedGameCount, 0);
      expect(updated.totalGames, 20);
    });

    test('player preserves multiple usernames per online platform', () {
      final player = const PlayerWorkspacePlayer(
            id: 'p1',
            displayName: 'Prep Target',
            createdAtMs: 123,
          )
          .withAccount(
            const PlayerWorkspaceAccount(
              source: PlayerWorkspaceSource.lichess,
              username: 'primaryLichess',
              gameCount: 10,
            ),
          )
          .withAccount(
            const PlayerWorkspaceAccount(
              source: PlayerWorkspaceSource.lichess,
              username: 'secondLichess',
              gameCount: 20,
            ),
          )
          .withAccount(
            const PlayerWorkspaceAccount(
              source: PlayerWorkspaceSource.chesscom,
              username: 'primaryChessCom',
              gameCount: 30,
            ),
          )
          .withAccount(
            const PlayerWorkspaceAccount(
              source: PlayerWorkspaceSource.chesscom,
              username: 'secondChessCom',
              gameCount: 40,
            ),
          );

      expect(player.accountsFor(PlayerWorkspaceSource.lichess), hasLength(2));
      expect(player.accountsFor(PlayerWorkspaceSource.chesscom), hasLength(2));
      expect(player.totalSourceGames, 100);

      final restored = PlayerWorkspacePlayer.fromJson(player.toJson())!;

      expect(restored.accountsFor(PlayerWorkspaceSource.lichess), hasLength(2));
      expect(
        restored.accountsFor(PlayerWorkspaceSource.chesscom),
        hasLength(2),
      );
      expect(restored.totalSourceGames, 100);

      final replaced = restored.withAccount(
        const PlayerWorkspaceAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'secondLichess',
          gameCount: 25,
        ),
      );

      expect(replaced.accountsFor(PlayerWorkspaceSource.lichess), hasLength(2));
      expect(
        replaced
            .accountsFor(PlayerWorkspaceSource.lichess)
            .singleWhere((account) => account.username == 'secondLichess')
            .gameCount,
        25,
      );

      final withoutPrimary = replaced.withoutAccountEntry(
        replaced.accountsFor(PlayerWorkspaceSource.lichess).first,
      );

      expect(
        withoutPrimary
            .accountsFor(PlayerWorkspaceSource.lichess)
            .map((account) => account.username),
        <String>['secondLichess'],
      );
    });
  });

  group('Player workspace notifier library selection', () {
    test(
      'adding the first player keeps the parent library unselected',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository();
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();

        await notifier.addManualPlayer('Magnus Carlsen');

        expect(notifier.state.players, hasLength(1));
        expect(notifier.state.players.single.displayName, 'Magnus Carlsen');
        expect(notifier.state.selectedPlayerId, isNull);
        expect(workspaceRepository.snapshot.selectedPlayerId, isNull);

        await notifier.selectPlayer(notifier.state.players.single.id);

        expect(notifier.state.selectedPlayer?.displayName, 'Magnus Carlsen');
        expect(
          workspaceRepository.snapshot.selectedPlayerId,
          notifier.state.players.single.id,
        );
      },
    );

    test('removing the opened player clears selected state', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository();
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Hikaru Nakamura');
      final playerId = notifier.state.players.single.id;
      await notifier.selectPlayer(playerId);

      await notifier.removePlayer(playerId);

      expect(notifier.state.players, isEmpty);
      expect(notifier.state.selectedPlayerId, isNull);
      expect(workspaceRepository.snapshot.players, isEmpty);
      expect(workspaceRepository.snapshot.selectedPlayerId, isNull);
    });

    test(
      'connecting and editing multiple platform usernames keeps each row',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository();
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();
        await notifier.addManualPlayer('Prep Target');
        final playerId = notifier.state.players.single.id;
        await notifier.selectPlayer(playerId);

        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'alpha',
        );
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'beta',
        );
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.chesscom,
          username: 'alphaChess',
        );
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.chesscom,
          username: 'betaChess',
        );

        var player = notifier.state.selectedPlayer!;
        expect(player.accountsFor(PlayerWorkspaceSource.lichess), hasLength(2));
        expect(
          player.accountsFor(PlayerWorkspaceSource.chesscom),
          hasLength(2),
        );

        final beta = player
            .accountsFor(PlayerWorkspaceSource.lichess)
            .singleWhere((account) => account.username == 'beta');
        await notifier.editExternalAccount(account: beta, username: 'gamma');

        player = notifier.state.selectedPlayer!;
        expect(
          player
              .accountsFor(PlayerWorkspaceSource.lichess)
              .map((account) => account.username),
          containsAll(<String>['alpha', 'gamma']),
        );
        expect(
          player
              .accountsFor(PlayerWorkspaceSource.lichess)
              .map((account) => account.username),
          isNot(contains('beta')),
        );

        final alpha = player
            .accountsFor(PlayerWorkspaceSource.lichess)
            .singleWhere((account) => account.username == 'alpha');
        await notifier.removeAccountEntry(alpha);

        expect(
          notifier.state.selectedPlayer!
              .accountsFor(PlayerWorkspaceSource.lichess)
              .map((account) => account.username),
          <String>['gamma'],
        );
        expect(
          notifier.state.selectedPlayer!.accountsFor(
            PlayerWorkspaceSource.chesscom,
          ),
          hasLength(2),
        );
      },
    );

    test('concurrent online account connects preserve both rows', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository();
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Prep Target');
      await notifier.selectPlayer(notifier.state.players.single.id);

      await Future.wait<void>([
        notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'alpha',
        ),
        notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.chesscom,
          username: 'alphaChess',
        ),
      ]);

      final player = notifier.state.selectedPlayer!;
      expect(
        player
            .accountsFor(PlayerWorkspaceSource.lichess)
            .map((account) => account.username),
        <String>['alpha'],
      );
      expect(
        player
            .accountsFor(PlayerWorkspaceSource.chesscom)
            .map((account) => account.username),
        <String>['alphachess'],
      );
    });

    test('concurrent source syncs preserve every source database', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository(
        root: temp,
        lichessPgnByUsername: const <String, String>{'alpha': _mergeGameOne},
        chessComPgnByUsername: const <String, String>{'hikaru': _mergeGameTwo},
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Prep Target');
      await notifier.selectPlayer(notifier.state.players.single.id);
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.lichess,
        username: 'alpha',
      );
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.chesscom,
        username: 'hikaru',
      );

      final accounts = notifier.state.selectedPlayer!.allAccounts;
      await Future.wait<void>([
        for (final account in accounts) notifier.syncAccount(account),
      ]);

      final player = notifier.state.selectedPlayer!;
      final lichess = player.account(PlayerWorkspaceSource.lichess)!;
      final chessCom = player.account(PlayerWorkspaceSource.chesscom)!;
      expect(lichess.gameCount, 1);
      expect(chessCom.gameCount, 1);
      expect(lichess.pgnPath, isNotNull);
      expect(chessCom.pgnPath, isNotNull);
      expect(player.combinedGameCount, 2);
      expect(player.combinedPgnPath, isNotNull);
      expect(notifier.state.operations, isEmpty);
    });

    test(
      'sync requests online games from the latest stored game date',
      () async {
        final sourcePgns = <String, String>{
          'alpha': '$_mergeGameOne\n\n$_mergeGameTwo',
        };
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          lichessPgnByUsername: sourcePgns,
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();
        await notifier.addManualPlayer('Prep Target');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'alpha',
        );

        var account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.lichess,
            )!;
        await notifier.syncAccount(account);

        expect(workspaceRepository.lichessSinceMsRequests.single, isNull);
        expect(workspaceRepository.replaceExistingRequests.single, isFalse);

        sourcePgns['alpha'] = _mergeGameThree;
        account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.lichess,
            )!;
        await notifier.syncAccount(account);

        expect(
          workspaceRepository.lichessSinceMsRequests.last,
          DateTime.utc(2026, 6, 2).millisecondsSinceEpoch,
        );
        expect(workspaceRepository.replaceExistingRequests.last, isFalse);

        final player = notifier.state.selectedPlayer!;
        final lichess = player.account(PlayerWorkspaceSource.lichess)!;
        expect(lichess.gameCount, 3);
        expect(
          splitPgnGames(await File(lichess.pgnPath!).readAsString()),
          hasLength(3),
        );
      },
    );

    test(
      'reinstall redownloads a source from scratch and replaces it',
      () async {
        final sourcePgns = <String, String>{
          'alpha': '$_mergeGameOne\n\n$_mergeGameTwo',
        };
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          lichessPgnByUsername: sourcePgns,
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();
        await notifier.addManualPlayer('Prep Target');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'alpha',
        );

        var account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.lichess,
            )!;
        await notifier.syncAccount(account);

        sourcePgns['alpha'] = _mergeGameThree;
        account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.lichess,
            )!;
        await notifier.reinstallAccount(account);

        expect(workspaceRepository.lichessSinceMsRequests.last, isNull);
        expect(workspaceRepository.replaceExistingRequests.last, isTrue);

        final player = notifier.state.selectedPlayer!;
        final lichess = player.account(PlayerWorkspaceSource.lichess)!;
        expect(lichess.gameCount, 1);
        final games = splitPgnGames(
          await File(lichess.pgnPath!).readAsString(),
        );
        expect(games, hasLength(1));
        expect(games.single, contains('Lichess import 3'));
        expect(player.combinedGameCount, 1);
      },
    );

    test('manual PGN imports become source and combined databases', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Prep Target');
      final playerId = notifier.state.players.single.id;
      await notifier.selectPlayer(playerId);

      await notifier.importManualPgn(
        label: 'Notebook A',
        pgn: '$_mergeGameOne\n\n$_mergeGameTwo',
      );
      await notifier.importManualPgn(
        label: 'Notebook B',
        pgn: '$_mergeGameTwo\n\n$_mergeGameThree',
      );

      final player = notifier.state.selectedPlayer!;
      final manualAccounts = player.accountsFor(PlayerWorkspaceSource.manual);

      expect(manualAccounts, hasLength(2));
      expect(manualAccounts.map((account) => account.gameCount), <int>[2, 2]);
      expect(player.combinedGameCount, 3);
      expect(player.combinedPgnPath, isNotNull);
      final combinedGames = splitPgnGames(
        await File(player.combinedPgnPath!).readAsString(),
      );
      expect(combinedGames, hasLength(3));
      expect(
        combinedGames.where((game) => game.contains('Lichess import 2')),
        hasLength(1),
      );

      final stats = await PlayerStatsRepository(
        database: () async => db,
      ).computePlayerStats(
        databasePath: player.combinedPgnPath!,
        aliases: const <String>['Prep Target', 'DrNykterstein'],
      );

      expect(stats.games, 3);
      expect(stats.overall.wins, 1);
      expect(stats.overall.draws, 1);
      expect(stats.overall.losses, 1);
    });

    test(
      'ChessEver player sync creates a source and combined database',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          chessEverPgnByPlayerId: const <String, String>{
            'ce-carlsen': '$_mergeGameOne\n\n$_mergeGameTwo',
          },
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();
        await notifier.addManualPlayer('Prep Target');
        final playerId = notifier.state.players.single.id;
        await notifier.selectPlayer(playerId);

        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-carlsen',
            fideId: '1503014',
            name: 'Carlsen, Magnus',
            gender: PlayerGender.male,
            fed: 'NOR',
            title: 'GM',
            ratingClassical: 2830,
          ),
        );
        final account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;

        await notifier.syncAccount(account);

        final player = notifier.state.selectedPlayer!;
        final chessever = player.account(PlayerWorkspaceSource.chessever)!;
        expect(chessever.externalId, 'ce-carlsen');
        expect(chessever.gameCount, 2);
        expect(chessever.pgnPath, isNotNull);
        expect(
          splitPgnGames(await File(chessever.pgnPath!).readAsString()),
          hasLength(2),
        );
        expect(player.combinedGameCount, 2);
        expect(player.combinedPgnPath, isNotNull);
        expect(
          splitPgnGames(await File(player.combinedPgnPath!).readAsString()),
          hasLength(2),
        );
      },
    );

    test('Lichess sync creates combined stats for the overview', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository(
        root: temp,
        lichessPgnByUsername: const <String, String>{
          'DrNykterstein': '$_mergeGameOne\n\n$_mergeGameTwo',
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Prep Target');
      final playerId = notifier.state.players.single.id;
      await notifier.selectPlayer(playerId);
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.lichess,
        username: 'DrNykterstein',
      );

      final account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.lichess,
          )!;
      await notifier.syncAccount(account);

      final player = notifier.state.selectedPlayer!;
      expect(player.combinedGameCount, 2);
      expect(player.combinedPgnPath, isNotNull);

      final stats = await PlayerStatsRepository(
        database: () async => db,
      ).computePlayerStats(
        databasePath: player.combinedPgnPath!,
        aliases: const <String>['Prep Target', 'DrNykterstein'],
      );

      expect(stats.games, 2);
      expect(stats.overall.wins, 1);
      expect(stats.overall.losses, 1);
    });

    test('Chess.com sync creates combined stats for the overview', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository(
        root: temp,
        chessComPgnByUsername: const <String, String>{
          'hikaru': '$_mergeGameOne\n\n$_mergeGameThree',
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Prep Target');
      final playerId = notifier.state.players.single.id;
      await notifier.selectPlayer(playerId);
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.chesscom,
        username: 'hikaru',
      );

      final account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chesscom,
          )!;
      await notifier.syncAccount(account);

      final player = notifier.state.selectedPlayer!;
      expect(player.combinedGameCount, 2);
      expect(player.combinedPgnPath, isNotNull);

      final stats = await PlayerStatsRepository(
        database: () async => db,
      ).computePlayerStats(
        databasePath: player.combinedPgnPath!,
        aliases: const <String>['Prep Target', 'hikaru', 'DrNykterstein'],
      );

      expect(stats.games, 2);
      expect(stats.overall.wins, 1);
      expect(stats.overall.draws, 1);
    });
  });

  group('Player workspace local import', () {
    test('merges downloaded PGNs without duplicating cached games', () async {
      final workspaceRepository = PlayerWorkspaceRepository();
      final localRepository = LocalChessDatabaseRepository(
        database: () async => db,
      );
      final path = '${temp.path}/workspace/lichess-drnykterstein.pgn';

      final first = await workspaceRepository.mergeIntoLocalDatabase(
        localRepository: localRepository,
        path: path,
        sourceLabel: 'Lichess: DrNykterstein',
        pgn: '$_mergeGameOne\n\n$_mergeGameTwo',
        playerAliases: const <String>['DrNykterstein'],
      );

      expect(first.stats.gameCount, 2);
      expect(first.stats.newGameCount, 2);
      expect(first.stats.winCount, 1);
      expect(first.stats.lossCount, 1);
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 2);
      expect(splitPgnGames(await File(path).readAsString()), hasLength(2));

      final second = await workspaceRepository.mergeIntoLocalDatabase(
        localRepository: localRepository,
        path: path,
        sourceLabel: 'Lichess: DrNykterstein',
        pgn: '$_mergeGameOne\n\n$_mergeGameTwo\n\n$_mergeGameThree',
        playerAliases: const <String>['DrNykterstein'],
      );

      expect(second.stats.gameCount, 3);
      expect(second.stats.newGameCount, 1);
      expect(second.stats.winCount, 1);
      expect(second.stats.drawCount, 1);
      expect(second.stats.lossCount, 1);
      expect(await _count(db, 'local_chess_databases'), 1);
      expect(await _count(db, 'local_chess_games'), 3);
      final afterAppend = splitPgnGames(await File(path).readAsString());
      expect(afterAppend, hasLength(3));
      expect(
        afterAppend.where((game) => game.contains('Lichess import 1')),
        hasLength(1),
      );

      final third = await workspaceRepository.mergeIntoLocalDatabase(
        localRepository: localRepository,
        path: path,
        sourceLabel: 'Lichess: DrNykterstein',
        pgn: '$_mergeGameOne\n\n$_mergeGameTwo\n\n$_mergeGameThree',
        playerAliases: const <String>['DrNykterstein'],
      );

      expect(third.stats.gameCount, 3);
      expect(third.stats.newGameCount, 0);
      expect(await _count(db, 'local_chess_games'), 3);
      expect(splitPgnGames(await File(path).readAsString()), hasLength(3));
    });
  });

  group('Player workspace public API profiles', () {
    test('stores Lichess profile game totals as available games', () async {
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((request) async {
          expect(request.url.host, 'lichess.org');
          expect(request.url.path, '/api/user/DrNykterstein');
          expect(request.headers['User-Agent'], contains('ChessEverDesktop'));
          return http.Response(
            jsonEncode({
              'username': 'DrNykterstein',
              'title': 'GM',
              'profile': {'country': 'NO'},
              'perfs': {
                'blitz': {'rating': 3200, 'games': 30},
                'rapid': {'rating': 2900, 'games': 12},
              },
              'count': {'all': 42},
            }),
            200,
          );
        }),
      );

      final account = await workspaceRepository.fetchLichessAccount(
        'DrNykterstein',
      );

      expect(account.username, 'DrNykterstein');
      expect(account.availableGameCount, 42);
      expect(account.gameCount, 0);
      expect(account.effectiveAvailableGameCount, 42);
      expect(account.downloadProgress, 0.0);
      expect(account.ratings['Blitz'], 3200);
      expect(account.country, 'NO');
    });

    test('stores Chess.com profile game totals as available games', () async {
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((request) async {
          expect(request.headers['User-Agent'], contains('ChessEverDesktop'));
          if (request.url.path == '/pub/player/hikaru') {
            return http.Response(
              jsonEncode({
                'username': 'hikaru',
                'player_id': 15448422,
                'name': 'Hikaru Nakamura',
                'avatar': 'https://images.chesscomfiles.com/profile.jpg',
                'country': 'https://api.chess.com/pub/country/US',
                'title': 'GM',
                'url': 'https://www.chess.com/member/Hikaru',
              }),
              200,
            );
          }
          expect(request.url.path, '/pub/player/hikaru/stats');
          return http.Response(
            jsonEncode({
              'chess_blitz': {
                'last': {'rating': 3300},
                'record': {'win': 3, 'draw': 1, 'loss': 2},
              },
              'chess_rapid': {
                'last': {'rating': 2900},
                'record': {'win': 4, 'draw': 0, 'loss': 1},
              },
            }),
            200,
          );
        }),
      );

      final account = await workspaceRepository.fetchChessComAccount('Hikaru');

      expect(account.username, 'hikaru');
      expect(account.displayName, 'Hikaru Nakamura');
      expect(account.availableGameCount, 11);
      expect(account.gameCount, 0);
      expect(account.winCount, 7);
      expect(account.drawCount, 1);
      expect(account.lossCount, 3);
      expect(account.ratings['Blitz'], 3300);
      expect(account.ratings['Rapid'], 2900);
      expect(account.country, 'US');
    });
  });

  group('Player workspace public API downloads', () {
    test('downloads ChessEver games by hydrating Gamebase PGNs', () async {
      final gamebaseRepository = _FakeGamebaseRepository(const <String, String>{
        'ce-1': _mergeGameOne,
        'ce-2': _mergeGameTwo,
      });
      final progressMessages = <String>[];
      final workspaceRepository = PlayerWorkspaceRepository();

      final downloaded = await workspaceRepository.downloadChessEverGames(
        repository: gamebaseRepository,
        playerId: 'ce-player',
        sinceDate: DateTime.utc(2026, 6, 2),
        onProgress: (message, _) => progressMessages.add(message),
      );

      expect(downloaded.source, PlayerWorkspaceSource.chessever);
      expect(downloaded.gameCount, 2);
      expect(downloaded.pgn, contains('Lichess import 1'));
      expect(downloaded.pgn, contains('Lichess import 2'));
      expect(gamebaseRepository.requestedPlayerIds, <String>['ce-player']);
      expect(gamebaseRepository.requestedIncludeData, <bool>[true]);
      expect(gamebaseRepository.requestedPageSizes, <int>[1000]);
      expect(gamebaseRepository.requestedDateFrom, <String?>['2026-06-02']);
      expect(gamebaseRepository.hydratedIds, <String>['ce-1', 'ce-2']);
      expect(progressMessages.first, startsWith('ChessEver: loading page 1'));
      expect(
        progressMessages,
        anyElement(
          equals(
            'ChessEver: 0/2 PGNs embedded; hydrating 2 missing PGNs '
            '(2 at a time)...',
          ),
        ),
      );
    });

    test('hydrates missing ChessEver PGNs concurrently', () async {
      final gamebaseRepository = _ConcurrentHydrationGamebaseRepository(
        const <String, String>{
          'ce-1': _mergeGameOne,
          'ce-2': _mergeGameTwo,
          'ce-3': _mergeGameThree,
        },
      );
      final workspaceRepository = PlayerWorkspaceRepository();

      final future = workspaceRepository.downloadChessEverGames(
        repository: gamebaseRepository,
        playerId: 'ce-player',
      );
      await gamebaseRepository.allHydrationsStarted.future.timeout(
        const Duration(seconds: 5),
      );

      expect(gamebaseRepository.maxInFlight, greaterThan(1));

      gamebaseRepository
        ..completeHydration('ce-3')
        ..completeHydration('ce-1')
        ..completeHydration('ce-2');
      final downloaded = await future.timeout(const Duration(seconds: 5));

      expect(downloaded.gameCount, 3);
      expect(
        downloaded.pgn.indexOf('Lichess import 1'),
        lessThan(downloaded.pgn.indexOf('Lichess import 2')),
      );
      expect(
        downloaded.pgn.indexOf('Lichess import 2'),
        lessThan(downloaded.pgn.indexOf('Lichess import 3')),
      );
    });

    test(
      'downloads Lichess games with since filtering and PGN headers',
      () async {
        final progressUpdates = <({String message, double? progress})>[];
        final workspaceRepository = PlayerWorkspaceRepository(
          client: MockClient((request) async {
            expect(request.method, 'GET');
            expect(request.url.host, 'lichess.org');
            expect(request.url.path, '/api/games/user/DrNykterstein');
            expect(request.url.queryParameters['since'], '1782864000000');
            expect(request.url.queryParameters, isNot(contains('rated')));
            expect(
              request.url.queryParameters['perfType'],
              contains('classical'),
            );
            expect(request.headers['Accept'], 'application/x-chess-pgn');
            expect(request.headers['User-Agent'], contains('ChessEverDesktop'));
            return http.Response(_mergeGameOne, 200);
          }),
        );

        final downloaded = await workspaceRepository.downloadLichessGames(
          username: 'DrNykterstein',
          sinceMs: DateTime.utc(2026, 7).millisecondsSinceEpoch,
          expectedGameCount: 2,
          onProgress:
              (message, progress) =>
                  progressUpdates.add((message: message, progress: progress)),
        );

        expect(downloaded.source, PlayerWorkspaceSource.lichess);
        expect(downloaded.gameCount, 1);
        expect(downloaded.pgn, contains('Lichess import 1'));
        expect(
          progressUpdates.map((update) => update.message),
          contains('Receiving Lichess games: 1 of about 2...'),
        );
        expect(
          progressUpdates.map((update) => update.progress).whereType<double>(),
          contains(0.5),
        );
      },
    );

    test('downloads Chess.com archives from the since month onward', () async {
      final requestedPaths = <String>[];
      final progressUpdates = <({String message, double? progress})>[];
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((request) async {
          requestedPaths.add(request.url.path);
          expect(request.headers['User-Agent'], contains('ChessEverDesktop'));
          if (request.url.path == '/pub/player/hikaru/games/archives') {
            expect(request.headers['Accept'], 'application/json');
            return http.Response(
              jsonEncode({
                'archives': [
                  'https://api.chess.com/pub/player/hikaru/games/2026/06',
                  'https://api.chess.com/pub/player/hikaru/games/2026/07',
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/pub/player/hikaru/games/2026/07/pgn');
          expect(request.headers['Accept'], 'application/x-chess-pgn');
          return http.Response(_mergeGameThree, 200);
        }),
      );

      final downloaded = await workspaceRepository.downloadChessComGames(
        username: 'Hikaru',
        sinceMs: DateTime.utc(2026, 7, 15).millisecondsSinceEpoch,
        onProgress:
            (message, progress) =>
                progressUpdates.add((message: message, progress: progress)),
      );

      expect(downloaded.source, PlayerWorkspaceSource.chesscom);
      expect(downloaded.gameCount, 1);
      expect(downloaded.pgn, contains('Lichess import 3'));
      expect(requestedPaths, [
        '/pub/player/hikaru/games/archives',
        '/pub/player/hikaru/games/2026/07/pgn',
      ]);
      expect(
        progressUpdates.first.message,
        'Chess.com: loading monthly archive list...',
      );
      expect(
        progressUpdates.map((update) => update.message),
        contains(
          'Chess.com: started 2026/07 (1/1); 0 done, 0 games received...',
        ),
      );
      expect(
        progressUpdates.map((update) => update.message),
        contains('Chess.com: 1/1 archives done; 1 games received...'),
      );
      expect(
        progressUpdates.map((update) => update.progress).whereType<double>(),
        contains(1.0),
      );
    });

    test('downloads Chess.com monthly archives concurrently', () async {
      final pending = <String, Completer<http.Response>>{};
      final allArchivesStarted = Completer<void>();
      var inFlight = 0;
      var maxInFlight = 0;
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((request) async {
          if (request.url.path == '/pub/player/hikaru/games/archives') {
            return http.Response(
              jsonEncode({
                'archives': [
                  'https://api.chess.com/pub/player/hikaru/games/2026/05',
                  'https://api.chess.com/pub/player/hikaru/games/2026/06',
                  'https://api.chess.com/pub/player/hikaru/games/2026/07',
                ],
              }),
              200,
            );
          }
          final path = request.url.path;
          final completer = Completer<http.Response>();
          pending[path] = completer;
          inFlight += 1;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          if (pending.length == 3 && !allArchivesStarted.isCompleted) {
            allArchivesStarted.complete();
          }
          final response = await completer.future;
          inFlight -= 1;
          return response;
        }),
      );

      final future = workspaceRepository.downloadChessComGames(
        username: 'Hikaru',
      );
      await allArchivesStarted.future.timeout(const Duration(seconds: 5));

      expect(maxInFlight, greaterThan(1));

      pending['/pub/player/hikaru/games/2026/07/pgn']!.complete(
        http.Response(_mergeGameThree, 200),
      );
      pending['/pub/player/hikaru/games/2026/05/pgn']!.complete(
        http.Response(_mergeGameOne, 200),
      );
      pending['/pub/player/hikaru/games/2026/06/pgn']!.complete(
        http.Response(_mergeGameTwo, 200),
      );
      final downloaded = await future.timeout(const Duration(seconds: 5));

      expect(downloaded.gameCount, 3);
      expect(
        downloaded.pgn.indexOf('Lichess import 1'),
        lessThan(downloaded.pgn.indexOf('Lichess import 2')),
      );
      expect(
        downloaded.pgn.indexOf('Lichess import 2'),
        lessThan(downloaded.pgn.indexOf('Lichess import 3')),
      );
    });
  });
}

Future<int> _count(resqlite.Database db, String table) async {
  final rows = await db.select('SELECT COUNT(*) AS count FROM $table');
  return rows.single['count'] as int;
}

const String _mergeGameOne = '''
[Event "Lichess import 1"]
[Site "https://lichess.org/import-one"]
[Date "2026.06.01"]
[Round "1"]
[White "DrNykterstein"]
[Black "Opponent One"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''';

const String _mergeGameTwo = '''
[Event "Lichess import 2"]
[Site "https://lichess.org/import-two"]
[Date "2026.06.02"]
[Round "1"]
[White "Opponent Two"]
[Black "DrNykterstein"]
[Result "1-0"]

1. d4 d5 2. c4 e6 1-0
''';

const String _mergeGameThree = '''
[Event "Lichess import 3"]
[Site "https://lichess.org/import-three"]
[Date "2026.06.03"]
[Round "1"]
[White "DrNykterstein"]
[Black "Opponent Three"]
[Result "1/2-1/2"]

1. c4 c5 2. Nc3 Nc6 1/2-1/2
''';

class _FakePlayerWorkspaceRepository extends PlayerWorkspaceRepository {
  _FakePlayerWorkspaceRepository({
    Directory? root,
    this.chessEverPgnByPlayerId = const <String, String>{},
    this.lichessPgnByUsername = const <String, String>{},
    this.chessComPgnByUsername = const <String, String>{},
  }) : root = root ?? Directory.systemTemp;

  final Directory root;
  final Map<String, String> chessEverPgnByPlayerId;
  final Map<String, String> lichessPgnByUsername;
  final Map<String, String> chessComPgnByUsername;
  PlayerWorkspaceSnapshot snapshot = const PlayerWorkspaceSnapshot();
  final lichessSinceMsRequests = <int?>[];
  final chessComSinceMsRequests = <int?>[];
  final chessEverSinceDateRequests = <DateTime?>[];
  final replaceExistingRequests = <bool>[];
  int _counter = 0;

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }

  @override
  Future<String> sourcePgnPath({
    required String playerId,
    required PlayerWorkspaceSource source,
    String? username,
  }) async {
    final dir = Directory(
      '${root.path}/player-workspace/${_fakeSafeFilePart(playerId)}',
    );
    await dir.create(recursive: true);
    final suffix = _fakeSafeFilePart(username ?? source.label);
    return '${dir.path}/${source.storageKey}-$suffix.pgn';
  }

  @override
  Future<String> combinedPgnPath({required String playerId}) async {
    final dir = Directory(
      '${root.path}/player-workspace/${_fakeSafeFilePart(playerId)}',
    );
    await dir.create(recursive: true);
    return '${dir.path}/combined.pgn';
  }

  @override
  PlayerWorkspacePlayer manualPlayer(String displayName) {
    _counter += 1;
    return PlayerWorkspacePlayer(
      id: 'manual-$_counter',
      displayName: displayName.trim(),
      createdAtMs: _counter,
    );
  }

  @override
  Future<PlayerWorkspaceAccount> fetchLichessAccount(String username) async {
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.lichess,
      username: username.trim(),
      displayName: username.trim(),
      availableGameCount: 100,
    );
  }

  @override
  Future<PlayerWorkspaceAccount> fetchChessComAccount(String username) async {
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.chesscom,
      username: username.trim().toLowerCase(),
      displayName: username.trim(),
      availableGameCount: 100,
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    lichessSinceMsRequests.add(sinceMs);
    final pgn = lichessPgnByUsername[username.trim()] ?? '';
    onProgress?.call('Downloading Lichess games...', null);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.lichess,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    chessComSinceMsRequests.add(sinceMs);
    final pgn = chessComPgnByUsername[username.trim().toLowerCase()] ?? '';
    onProgress?.call('Downloading Chess.com games...', null);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chesscom,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessEverGames({
    required GamebaseRepository repository,
    required String playerId,
    DateTime? sinceDate,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    chessEverSinceDateRequests.add(sinceDate);
    final pgn = chessEverPgnByPlayerId[playerId] ?? '';
    onProgress?.call('Downloading ChessEver games...', null);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
    );
  }

  @override
  Future<PlayerWorkspaceImportResult> mergeIntoLocalDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String path,
    required String sourceLabel,
    required String pgn,
    required Iterable<String> playerAliases,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
  }) {
    replaceExistingRequests.add(replaceExisting);
    return super.mergeIntoLocalDatabase(
      localRepository: localRepository,
      path: path,
      sourceLabel: sourceLabel,
      pgn: pgn,
      playerAliases: playerAliases,
      replaceExisting: replaceExisting,
      onProgress: onProgress,
    );
  }
}

class _FakeGamebaseRepository extends GamebaseRepository {
  _FakeGamebaseRepository(this.pgnById) : super(Dio());

  final Map<String, String> pgnById;
  final requestedPlayerIds = <String>[];
  final requestedIncludeData = <bool>[];
  final requestedPageSizes = <int>[];
  final requestedDateFrom = <String?>[];
  final hydratedIds = <String>[];

  @override
  Future<Map<String, dynamic>> getPlayerGames({
    required String playerId,
    String? q,
    String color = 'all',
    String? timeControl,
    String? outcome,
    String? eco,
    String? opening,
    String? variation,
    String? event,
    String? site,
    String? dateFrom,
    String? dateTo,
    String? opponentId,
    int? ratingFrom,
    int? ratingTo,
    bool? isOnline,
    int pageNumber = 0,
    int pageSize = 100,
    bool includeData = false,
  }) async {
    requestedPlayerIds.add(playerId);
    requestedIncludeData.add(includeData);
    requestedPageSizes.add(pageSize);
    requestedDateFrom.add(dateFrom);
    return <String, dynamic>{
      'data':
          pageNumber == 0
              ? <Map<String, dynamic>>[
                for (final id in pgnById.keys) <String, dynamic>{'id': id},
              ]
              : const <Map<String, dynamic>>[],
      'metadata': const <String, dynamic>{'hasMore': false},
    };
  }

  @override
  Future<GamebaseGameWithPgn?> getGameWithPgn(String id) async {
    hydratedIds.add(id);
    final pgn = pgnById[id];
    if (pgn == null) return null;
    return GamebaseGameWithPgn(
      id: id,
      date: DateTime.utc(2026, 6),
      result: GameResult.whiteWins,
      timeControl: TimeControl.blitz,
      pgn: pgn,
    );
  }
}

class _ConcurrentHydrationGamebaseRepository extends _FakeGamebaseRepository {
  _ConcurrentHydrationGamebaseRepository(super.pgnById);

  final allHydrationsStarted = Completer<void>();
  final _pending = <String, Completer<GamebaseGameWithPgn?>>{};
  var _inFlight = 0;
  var maxInFlight = 0;

  @override
  Future<GamebaseGameWithPgn?> getGameWithPgn(String id) async {
    hydratedIds.add(id);
    final completer = Completer<GamebaseGameWithPgn?>();
    _pending[id] = completer;
    _inFlight += 1;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    if (_pending.length == pgnById.length &&
        !allHydrationsStarted.isCompleted) {
      allHydrationsStarted.complete();
    }
    final result = await completer.future;
    _inFlight -= 1;
    return result;
  }

  void completeHydration(String id) {
    final pgn = pgnById[id];
    _pending[id]?.complete(
      pgn == null
          ? null
          : GamebaseGameWithPgn(
            id: id,
            date: DateTime.utc(2026, 6),
            result: GameResult.whiteWins,
            timeControl: TimeControl.blitz,
            pgn: pgn,
          ),
    );
  }
}

String _fakeSafeFilePart(String value) {
  final cleaned = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return cleaned.isEmpty ? 'player' : cleaned;
}
