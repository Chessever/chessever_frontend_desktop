import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_stats_repository.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
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
    await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
    await db.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  group('Player workspace PGN helpers', () {
    test(
      'Combined rebuild uses the complete Combined cache instead of a partial source union',
      () async {
        final sourcePaths = <String>[
          '${temp.path}/chessever.pgn',
          '${temp.path}/lichess.pgn',
          '${temp.path}/chesscom.pgn',
        ];
        await File(sourcePaths[0]).writeAsString(_mergeGameOne);
        await File(sourcePaths[1]).writeAsString(_mergeGameTwo);
        await File(sourcePaths[2]).writeAsString(_mergeGameThree);
        final localRepository = _PartialSourceUnionStatsRepository(
          database: () async => db,
        );
        final workspaceRepository = PlayerWorkspaceRepository(
          supportDirectory: () async => temp,
        );

        final result = await workspaceRepository.rebuildCombinedDatabase(
          localRepository: localRepository,
          playerId: 'vasif-combined-authority',
          playerName: 'GM Vasif Durarbayli',
          playerFideId: '13402935',
          sourcePaths: sourcePaths,
          sources: <PlayerWorkspaceCombinedSource>[
            PlayerWorkspaceCombinedSource(
              path: sourcePaths[0],
              source: PlayerWorkspaceSource.chessever,
            ),
            PlayerWorkspaceCombinedSource(
              path: sourcePaths[1],
              source: PlayerWorkspaceSource.lichess,
            ),
            PlayerWorkspaceCombinedSource(
              path: sourcePaths[2],
              source: PlayerWorkspaceSource.chesscom,
            ),
          ],
          playerAliases: const <String>['GM Vasif Durarbayli', 'Durarbayli'],
        );

        expect(result.stats.gameCount, 20226);
        expect(localRepository.combinedPathRequests, 1);
        expect(localRepository.sourceUnionRequests, 0);
      },
    );

    test(
      'cold Combined rebuild keeps the UI event loop responsive',
      () async {
        final sourceFile = File('${temp.path}/cold-chessever-source.pgn');
        await sourceFile.writeAsString(_largeChessEverPgn(1000));
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );

        final stopwatch = Stopwatch()..start();
        var lastTickUs = stopwatch.elapsedMicroseconds;
        var maxTickGapUs = 0;
        var tickCount = 0;
        var phase = 'starting';
        var phaseAtMaxGap = phase;
        final timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
          final nowUs = stopwatch.elapsedMicroseconds;
          final gapUs = nowUs - lastTickUs;
          if (gapUs > maxTickGapUs) {
            maxTickGapUs = gapUs;
            phaseAtMaxGap = phase;
          }
          lastTickUs = nowUs;
          tickCount++;
        });
        await Future<void>.delayed(const Duration(milliseconds: 12));

        final result = await workspaceRepository.rebuildCombinedDatabase(
          localRepository: localRepository,
          playerId: 'vasif-cold-install',
          playerName: 'Vasif Durarbayli',
          playerFideId: '13402935',
          sourcePaths: <String>[sourceFile.path],
          playerAliases: const <String>['Vasif Durarbayli', 'Durarbayli,Vasif'],
          onProgress: (message, _) => phase = message,
        );
        await Future<void>.delayed(const Duration(milliseconds: 12));
        timer.cancel();

        expect(result.stats.gameCount, 1000);
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 15)),
          reason: 'A 1,000-game cold rebuild should complete promptly.',
        );
        expect(tickCount, greaterThan(10));
        expect(
          maxTickGapUs,
          lessThan(25000),
          reason:
              'A cold Combined rebuild must not block the UI event loop for '
              'longer than roughly one 60 Hz frame. Actual max gap: '
              '${(maxTickGapUs / 1000).toStringAsFixed(1)} ms during '
              '"$phaseAtMaxGap".',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('formats generated PGN file names with an upper-case source', () {
      expect(
        playerWorkspaceSourceFileName(
          source: PlayerWorkspaceSource.lichess,
          username: 'magnuscarlsen',
          fideId: '13402935',
        ),
        'LICHESS_13402935_CHESSEVER_MAGNUSCARLSEN.pgn',
      );
      expect(
        playerWorkspaceSourceFileName(
          source: PlayerWorkspaceSource.chesscom,
          username: 'Hikaru',
          playerName: 'Hikaru Nakamura',
        ),
        'CHESS.COM_HIKARU_NAKAMURA_CHESSEVER_HIKARU.pgn',
      );
      expect(
        playerWorkspaceSourceFileName(
          source: PlayerWorkspaceSource.chessever,
          username: 'Magnus Carlsen',
          fideId: '13402935',
        ),
        'CHESSEVER_13402935_CHESSEVER_MAGNUS_CARLSEN.pgn',
      );
      expect(
        playerWorkspaceSourceFileName(
          source: PlayerWorkspaceSource.manual,
          username: 'my games',
          playerName: 'Prep Target',
        ),
        'MANUAL_PGN_PREP_TARGET_CHESSEVER_MY_GAMES.pgn',
      );
      expect(
        playerWorkspaceCombinedFileName(fideId: '13402935'),
        'COMBINED_13402935_CHESSEVER.pgn',
      );
    });

    test('sanitizes file-system-hostile characters in the handle', () {
      expect(
        playerWorkspaceSourceFileName(
          source: PlayerWorkspaceSource.lichess,
          username: 'a/b:c*d?',
          playerName: 'Prep Target',
        ),
        'LICHESS_PREP_TARGET_CHESSEVER_A_B_C_D.pgn',
      );
      // A handle that collapses to nothing still keeps player/app identity.
      expect(
        playerWorkspaceSourceFileName(
          source: PlayerWorkspaceSource.lichess,
          username: '///',
          playerName: 'Prep Target',
        ),
        'LICHESS_PREP_TARGET_CHESSEVER.pgn',
      );
    });

    test('ChessEver-created player ids use the player name, not UUID', () {
      final player = PlayerWorkspaceRepository().playerFromChessEver(
        const GamebasePlayer(
          id: '123e4567-e89b-12d3-a456-426614174000',
          fideId: '1503014',
          name: 'Carlsen, Magnus',
          gender: PlayerGender.male,
          fed: 'NOR',
          title: 'GM',
        ),
      );

      expect(player.id, contains('gm-magnus-carlsen'));
      expect(player.id, isNot(contains('123e4567')));
    });

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

    test('maps import worker progress into the post-save import range', () {
      expect(mapPlayerWorkspaceImportWorkerProgress(0), closeTo(0.10, 1e-9));
      expect(mapPlayerWorkspaceImportWorkerProgress(0.5), closeTo(0.54, 1e-9));
      expect(mapPlayerWorkspaceImportWorkerProgress(1), closeTo(0.98, 1e-9));
      expect(mapPlayerWorkspaceImportWorkerProgress(-1), closeTo(0.10, 1e-9));
      expect(mapPlayerWorkspaceImportWorkerProgress(2), closeTo(0.98, 1e-9));
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

    test('snapshot round-trips pending player deletions', () {
      const pendingPlayer = PlayerWorkspacePlayer(
        id: 'pending-p1',
        displayName: 'Pending Player',
        createdAtMs: 456,
        accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
          PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chesscom,
            username: 'pending-player',
            pgnPath: '/old/player-workspace/pending-p1/CHESSCOM.pgn',
            gameCount: 12,
          ),
        },
        combinedPgnPath:
            '/old/player-workspace/pending-p1/COMBINED_PENDING.pgn',
        combinedGameCount: 12,
      );
      const snapshot = PlayerWorkspaceSnapshot(
        pendingDeletions: <PlayerWorkspacePlayer>[pendingPlayer],
        pendingDeletionExtraPaths: <String, List<String>>{
          'pending-p1': <String>['/old/player-workspace/pending-p1/STALE.pgn'],
        },
      );

      final restored = PlayerWorkspaceSnapshot.fromJson(snapshot.toJson());

      expect(restored.pendingDeletions, hasLength(1));
      expect(restored.pendingDeletions.single.id, pendingPlayer.id);
      expect(
        restored.pendingDeletions.single
            .account(PlayerWorkspaceSource.chesscom)
            ?.pgnPath,
        '/old/player-workspace/pending-p1/CHESSCOM.pgn',
      );
      expect(
        restored.pendingDeletions.single.combinedPgnPath,
        '/old/player-workspace/pending-p1/COMBINED_PENDING.pgn',
      );
      expect(restored.pendingDeletionExtraPaths['pending-p1'], <String>[
        '/old/player-workspace/pending-p1/STALE.pgn',
      ]);
    });

    test('older snapshots default pending player deletions to empty', () {
      final restored = PlayerWorkspaceSnapshot.fromJson(const {
        'players': <Object?>[],
        'selectedPlayerId': null,
      });

      expect(restored.pendingDeletions, isEmpty);
      expect(restored.pendingDeletionExtraPaths, isEmpty);
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

    test('rebases generated PGN paths to the current support root', () async {
      final oldSupport = Directory(p.join(temp.path, 'old-support'));
      final newSupport = Directory(p.join(temp.path, 'new-support'));
      const playerId = 'player-123-prep-target';
      final oldWorkspace = Directory(
        p.join(oldSupport.path, 'player-workspace', playerId),
      );
      await oldWorkspace.create(recursive: true);
      await newSupport.create(recursive: true);
      final sourceFile = File(p.join(oldWorkspace.path, 'LICHESS_PREP.pgn'));
      final combinedFile = File(p.join(oldWorkspace.path, 'COMBINED_PREP.pgn'));
      await sourceFile.writeAsString('[Event "old source"]\n');
      await combinedFile.writeAsString('[Event "old combined"]\n');

      final repository = PlayerWorkspaceRepository(
        supportDirectory: () async => newSupport,
      );
      final normalized = await repository
          .normalizeGeneratedPathsForCurrentSupportRoot(
            PlayerWorkspaceSnapshot(
              selectedPlayerId: playerId,
              players: <PlayerWorkspacePlayer>[
                PlayerWorkspacePlayer(
                  id: playerId,
                  displayName: 'Prep Target',
                  createdAtMs: 123,
                  accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                    PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                      source: PlayerWorkspaceSource.lichess,
                      username: 'prep',
                      pgnPath: sourceFile.path,
                      gameCount: 1,
                    ),
                  },
                  combinedPgnPath: combinedFile.path,
                  combinedGameCount: 1,
                ),
              ],
            ),
          );

      final player = normalized.players.single;
      final newSourcePath = p.join(
        newSupport.path,
        'player-workspace',
        playerId,
        'LICHESS_PREP.pgn',
      );
      final newCombinedPath = p.join(
        newSupport.path,
        'player-workspace',
        playerId,
        'COMBINED_PREP.pgn',
      );
      expect(
        player.account(PlayerWorkspaceSource.lichess)!.pgnPath,
        newSourcePath,
      );
      expect(player.combinedPgnPath, newCombinedPath);
      expect(
        await File(newSourcePath).readAsString(),
        '[Event "old source"]\n',
      );
      expect(
        await File(newCombinedPath).readAsString(),
        '[Event "old combined"]\n',
      );
    });

    test(
      'preserves pending-deletion paths at their original support root',
      () async {
        final oldSupport = Directory(p.join(temp.path, 'pending-old-support'));
        final newSupport = Directory(p.join(temp.path, 'pending-new-support'));
        const playerId = 'player-456-pending-target';
        final oldWorkspace = Directory(
          p.join(oldSupport.path, 'player-workspace', playerId),
        );
        await oldWorkspace.create(recursive: true);
        await newSupport.create(recursive: true);
        final sourceFile = File(
          p.join(oldWorkspace.path, 'CHESSCOM_PENDING.pgn'),
        );
        final combinedFile = File(
          p.join(oldWorkspace.path, 'COMBINED_PENDING.pgn'),
        );
        await sourceFile.writeAsString('[Event "pending source"]\n');
        await combinedFile.writeAsString('[Event "pending combined"]\n');

        final repository = PlayerWorkspaceRepository(
          supportDirectory: () async => newSupport,
        );
        final normalized = await repository
            .normalizeGeneratedPathsForCurrentSupportRoot(
              PlayerWorkspaceSnapshot(
                pendingDeletions: <PlayerWorkspacePlayer>[
                  PlayerWorkspacePlayer(
                    id: playerId,
                    displayName: 'Pending Target',
                    createdAtMs: 456,
                    accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                      PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
                        source: PlayerWorkspaceSource.chesscom,
                        username: 'pending-target',
                        pgnPath: sourceFile.path,
                        gameCount: 1,
                      ),
                    },
                    combinedPgnPath: combinedFile.path,
                    combinedGameCount: 1,
                  ),
                ],
              ),
            );

        final pending = normalized.pendingDeletions.single;
        final newSourcePath = p.join(
          newSupport.path,
          'player-workspace',
          playerId,
          'CHESSCOM_PENDING.pgn',
        );
        final newCombinedPath = p.join(
          newSupport.path,
          'player-workspace',
          playerId,
          'COMBINED_PENDING.pgn',
        );
        expect(
          pending.account(PlayerWorkspaceSource.chesscom)!.pgnPath,
          sourceFile.path,
        );
        expect(pending.combinedPgnPath, combinedFile.path);
        expect(await sourceFile.exists(), isTrue);
        expect(await combinedFile.exists(), isTrue);
        expect(await File(newSourcePath).exists(), isFalse);
        expect(await File(newCombinedPath).exists(), isFalse);
      },
    );

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
      'load repairs stale Players and Library Combined counts from the Combined path',
      () async {
        final registry = _CapturedLocalLibraryRegistry();
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final playerDir = Directory('${temp.path}/player-workspace/vasif');
        await playerDir.create(recursive: true);
        final chesseverPath = '${playerDir.path}/chessever.pgn';
        final lichessPath = '${playerDir.path}/lichess.pgn';
        final chessComPath = '${playerDir.path}/chesscom.pgn';
        final combinedPath = '${playerDir.path}/combined.pgn';
        await File(chesseverPath).writeAsString(_mergeGameOne);
        await File(lichessPath).writeAsString(_mergeGameTwo);
        await File(chessComPath).writeAsString(_mergeGameThree);
        await File(combinedPath).writeAsString('''
[Event "Combined"]
[$playerWorkspaceCombinedVersionTag "$playerWorkspaceCombinedFormatVersion"]
[White "Durarbayli"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5 1-0
''');
        workspaceRepository.snapshot = PlayerWorkspaceSnapshot(
          selectedPlayerId: 'vasif',
          players: <PlayerWorkspacePlayer>[
            PlayerWorkspacePlayer(
              id: 'vasif',
              displayName: 'GM Vasif Durarbayli',
              createdAtMs: 1,
              fideId: '13402935',
              accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.chessever,
                  username: 'Vasif Durarbayli',
                  pgnPath: chesseverPath,
                  gameCount: 3982,
                ),
                PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.lichess,
                  username: 'Durarbayli',
                  pgnPath: lichessPath,
                  gameCount: 6016,
                ),
                PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.chesscom,
                  username: 'durarbayli',
                  pgnPath: chessComPath,
                  gameCount: 10573,
                ),
              },
              combinedPgnPath: combinedPath,
              combinedGameCount: 9998,
              combinedBuiltAtMs: 1,
            ),
          ],
        );
        final localRepository = _PartialSourceUnionStatsRepository(
          database: () async => db,
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: localRepository,
          localDatabaseRegistrar: registry.registerAll,
        );

        await notifier.load();

        expect(notifier.state.selectedPlayer!.combinedGameCount, 20226);
        expect(registry.registered[combinedPath]?.gameCount, 20226);
        expect(
          registry.registered[combinedPath]?.playerWorkspaceSource,
          PlayerWorkspaceSource.combined.storageKey,
        );
        expect(
          workspaceRepository.snapshot.players.single.combinedGameCount,
          20226,
        );
      },
    );

    test(
      'load registers existing UUID workspace paths under player name',
      () async {
        final registry = _CapturedLocalLibraryRegistry();
        final workspaceRepository =
            _FakePlayerWorkspaceRepository()
              ..snapshot = const PlayerWorkspaceSnapshot(
                selectedPlayerId:
                    'player-1-123e4567-e89b-12d3-a456-426614174000',
                players: <PlayerWorkspacePlayer>[
                  PlayerWorkspacePlayer(
                    id: 'player-1-123e4567-e89b-12d3-a456-426614174000',
                    displayName: 'Magnus Carlsen',
                    createdAtMs: 1,
                    accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                      PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                        source: PlayerWorkspaceSource.lichess,
                        username: 'DrNykterstein',
                        pgnPath: '/tmp/player-workspace/uuid/lichess.pgn',
                        gameCount: 12,
                        lastSyncAtMs: 1000,
                      ),
                    },
                    combinedPgnPath: '/tmp/player-workspace/uuid/combined.pgn',
                    combinedGameCount: 12,
                    combinedBuiltAtMs: 2000,
                  ),
                ],
              );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
          localDatabaseRegistrar: registry.registerAll,
        );

        await notifier.load();

        expect(
          registry
              .registered['/tmp/player-workspace/uuid/lichess.pgn']
              ?.groupLabel,
          'Magnus Carlsen',
        );
        expect(
          registry
              .registered['/tmp/player-workspace/uuid/combined.pgn']
              ?.groupLabel,
          'Magnus Carlsen',
        );
        expect(
          registry
              .registered['/tmp/player-workspace/uuid/lichess.pgn']
              ?.playerWorkspaceSource,
          PlayerWorkspaceSource.lichess.storageKey,
        );
        expect(
          registry
              .registered['/tmp/player-workspace/uuid/combined.pgn']
              ?.playerWorkspaceSource,
          PlayerWorkspaceSource.combined.storageKey,
        );
        expect(
          registry.registered.values
              .map((metadata) => metadata.groupId)
              .toSet(),
          contains(
            'player-workspace:player-1-123e4567-e89b-12d3-a456-426614174000',
          ),
        );
      },
    );

    test(
      'source sync, combined rebuild, rename, and delete update library names',
      () async {
        final registry = _CapturedLocalLibraryRegistry();
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          lichessPgnByUsername: const <String, String>{
            'alpha': '$_mergeGameOne\n\n$_mergeGameTwo',
          },
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
          localDatabaseRegistrar: registry.registerAll,
          localDatabaseUnregistrar: registry.unregister,
        );
        await notifier.load();
        await notifier.addManualPlayer('Prep Target');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'alpha',
        );

        await notifier.syncAccount(
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.lichess,
          )!,
        );

        var player = notifier.state.selectedPlayer!;
        final sourcePath =
            player.account(PlayerWorkspaceSource.lichess)!.pgnPath!;
        final combinedPath = player.combinedPgnPath!;
        expect(registry.registered[sourcePath]?.groupLabel, 'Prep Target');
        expect(registry.registered[sourcePath]?.gameCount, 2);
        expect(registry.registered[combinedPath]?.groupLabel, 'Prep Target');
        expect(registry.registered[combinedPath]?.gameCount, 2);

        await notifier.renamePlayer(player.id, 'Readable Prep Target');

        player = notifier.state.selectedPlayer!;
        expect(
          registry.registered[sourcePath]?.groupLabel,
          'Readable Prep Target',
        );
        expect(
          registry.registered[combinedPath]?.groupLabel,
          'Readable Prep Target',
        );

        await notifier.removePlayer(player.id);
        await notifier.debugDrainPlayerCleanup();

        expect(registry.unregistered, contains(sourcePath));
        expect(registry.unregistered, contains(combinedPath));
      },
    );

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
      await notifier.debugDrainPlayerCleanup();

      expect(notifier.state.players, isEmpty);
      expect(notifier.state.selectedPlayerId, isNull);
      expect(workspaceRepository.snapshot.players, isEmpty);
      expect(workspaceRepository.snapshot.selectedPlayerId, isNull);
    });

    test(
      'removePlayer detaches silent cleanup from the visible action',
      () async {
        final gate = Completer<void>();
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = _BlockingPurgeLocalRepository(db, gate);
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: localRepository,
        );
        await notifier.load();
        await notifier.addManualPlayer('Heavy Prep');
        final playerId = notifier.state.players.single.id;
        await notifier.selectPlayer(playerId);

        var visibleActionCompleted = false;
        final removal = notifier.removePlayer(playerId);
        removal.then((_) => visibleActionCompleted = true);
        await pumpEventQueue();

        try {
          expect(
            visibleActionCompleted,
            isTrue,
            reason:
                'The trash action must not await the potentially long purge.',
          );
          expect(notifier.state.players, isEmpty);
          expect(notifier.state.selectedPlayerId, isNull);
          expect(workspaceRepository.snapshot.players, isEmpty);
          expect(
            workspaceRepository.snapshot.pendingDeletions.map(
              (player) => player.id,
            ),
            <String>[playerId],
          );
          expect(localRepository.purgeCalls, 0);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(localRepository.purgeCalls, 1);
          expect(localRepository.requestedBatchSize, 512);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await removal;
          await notifier.debugDrainPlayerCleanup();
          expect(workspaceRepository.snapshot.pendingDeletions, isEmpty);
        }
      },
    );

    test(
      'library source deletion removes that player account and clears combined',
      () async {
        final registry = _CapturedLocalLibraryRegistry();
        final sourcePath = '${temp.path}/player-workspace/player-1/alpha.pgn';
        final remainingPath = '${temp.path}/player-workspace/player-1/beta.pgn';
        final combinedPath =
            '${temp.path}/player-workspace/player-1/combined.pgn';
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp)
          ..snapshot = PlayerWorkspaceSnapshot(
            selectedPlayerId: 'player-1',
            players: <PlayerWorkspacePlayer>[
              PlayerWorkspacePlayer(
                id: 'player-1',
                displayName: 'Prep Target',
                createdAtMs: 1,
                accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                  PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                    source: PlayerWorkspaceSource.lichess,
                    username: 'alpha',
                    pgnPath: sourcePath,
                    gameCount: 4,
                  ),
                },
                additionalAccounts: <PlayerWorkspaceAccount>[
                  PlayerWorkspaceAccount(
                    source: PlayerWorkspaceSource.lichess,
                    username: 'beta',
                    pgnPath: remainingPath,
                    gameCount: 5,
                  ),
                ],
                combinedPgnPath: combinedPath,
                combinedGameCount: 9,
                combinedBuiltAtMs: 2000,
              ),
            ],
          );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
          localDatabaseRegistrar: registry.registerAll,
          localDatabaseUnregistrar: registry.unregister,
        );
        await notifier.load();

        await notifier.syncDeletedLibraryDatabasePath(
          sourcePath,
          playerId: 'player-1',
        );

        final player = notifier.state.selectedPlayer!;
        expect(
          player
              .accountsFor(PlayerWorkspaceSource.lichess)
              .map((account) => account.username),
          <String>['beta'],
        );
        expect(player.combinedPgnPath, isNull);
        expect(player.combinedGameCount, 0);
        expect(
          workspaceRepository.snapshot.players.single.combinedPgnPath,
          isNull,
        );
        expect(registry.unregistered, contains(sourcePath));
        expect(registry.unregistered, contains(combinedPath));
      },
    );

    test(
      'library last source deletion leaves the player without sources',
      () async {
        final registry = _CapturedLocalLibraryRegistry();
        final sourcePath = '${temp.path}/player-workspace/player-1/alpha.pgn';
        final combinedPath =
            '${temp.path}/player-workspace/player-1/combined.pgn';
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp)
          ..snapshot = PlayerWorkspaceSnapshot(
            selectedPlayerId: 'player-1',
            players: <PlayerWorkspacePlayer>[
              PlayerWorkspacePlayer(
                id: 'player-1',
                displayName: 'Prep Target',
                createdAtMs: 1,
                accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                  PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                    source: PlayerWorkspaceSource.lichess,
                    username: 'alpha',
                    pgnPath: sourcePath,
                    gameCount: 4,
                  ),
                },
                combinedPgnPath: combinedPath,
                combinedGameCount: 4,
                combinedBuiltAtMs: 2000,
              ),
            ],
          );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
          localDatabaseRegistrar: registry.registerAll,
          localDatabaseUnregistrar: registry.unregister,
        );
        await notifier.load();

        await notifier.syncDeletedLibraryDatabasePath(
          sourcePath,
          playerId: 'player-1',
        );

        expect(notifier.state.players, hasLength(1));
        expect(notifier.state.selectedPlayerId, 'player-1');
        final player = notifier.state.players.single;
        expect(player.accounts, isEmpty);
        expect(player.additionalAccounts, isEmpty);
        expect(player.combinedPgnPath, isNull);
        expect(player.combinedGameCount, 0);
        expect(workspaceRepository.snapshot.players, hasLength(1));
        expect(workspaceRepository.snapshot.selectedPlayerId, 'player-1');
        expect(registry.unregistered, contains(sourcePath));
        expect(registry.unregistered, contains(combinedPath));
      },
    );

    test(
      'library player folder deletion waits for initial player load',
      () async {
        final registry = _CapturedLocalLibraryRegistry();
        final loadGate = Completer<void>();
        final sourcePath = '${temp.path}/player-workspace/player-1/alpha.pgn';
        final combinedPath =
            '${temp.path}/player-workspace/player-1/combined.pgn';
        final workspaceRepository = _FakePlayerWorkspaceRepository(
            root: temp,
            loadGate: loadGate,
          )
          ..snapshot = PlayerWorkspaceSnapshot(
            selectedPlayerId: 'player-1',
            players: <PlayerWorkspacePlayer>[
              PlayerWorkspacePlayer(
                id: 'player-1',
                displayName: 'Prep Target',
                createdAtMs: 1,
                accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                  PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
                    source: PlayerWorkspaceSource.chessever,
                    username: 'Prep Target',
                    pgnPath: sourcePath,
                    gameCount: 4,
                  ),
                },
                combinedPgnPath: combinedPath,
                combinedGameCount: 4,
                combinedBuiltAtMs: 2000,
              ),
            ],
          );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
          localDatabaseRegistrar: registry.registerAll,
          localDatabaseUnregistrar: registry.unregister,
        );

        final sync = notifier.syncDeletedLibraryPlayerFolder(
          'player-1',
          deletedPaths: <String>[sourcePath, combinedPath],
        );
        await Future<void>.delayed(Duration.zero);
        expect(notifier.state.isLoading, isTrue);

        loadGate.complete();
        await sync;
        await notifier.debugDrainPlayerCleanup();

        expect(notifier.state.players, isEmpty);
        expect(workspaceRepository.snapshot.players, isEmpty);
        expect(
          registry.unregistered,
          containsAll(<String>[sourcePath, combinedPath]),
        );
      },
    );

    test('library player folder deletion removes the whole player', () async {
      final registry = _CapturedLocalLibraryRegistry();
      final sourcePath = '${temp.path}/player-workspace/player-1/alpha.pgn';
      final extraPath = '${temp.path}/player-workspace/player-1/beta.pgn';
      final combinedPath =
          '${temp.path}/player-workspace/player-1/combined.pgn';
      final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp)
        ..snapshot = PlayerWorkspaceSnapshot(
          selectedPlayerId: 'player-1',
          players: <PlayerWorkspacePlayer>[
            PlayerWorkspacePlayer(
              id: 'player-1',
              displayName: 'Prep Target',
              createdAtMs: 1,
              accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.lichess,
                  username: 'alpha',
                  pgnPath: sourcePath,
                  gameCount: 4,
                ),
              },
              additionalAccounts: <PlayerWorkspaceAccount>[
                PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.chesscom,
                  username: 'beta',
                  pgnPath: extraPath,
                  gameCount: 6,
                ),
              ],
              combinedPgnPath: combinedPath,
              combinedGameCount: 10,
              combinedBuiltAtMs: 2000,
            ),
          ],
        );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
        localDatabaseRegistrar: registry.registerAll,
        localDatabaseUnregistrar: registry.unregister,
        localDatabasePlayerUnregistrar: registry.unregisterPlayerWorkspace,
      );
      await notifier.load();

      await notifier.syncDeletedLibraryPlayerFolder(
        'legacy-player-folder-name',
        deletedPaths: <String>[sourcePath, extraPath, combinedPath],
      );
      await notifier.debugDrainPlayerCleanup();

      expect(notifier.state.players, isEmpty);
      expect(workspaceRepository.snapshot.players, isEmpty);
      expect(
        registry.unregistered,
        containsAll(<String>[sourcePath, extraPath, combinedPath]),
      );
    });

    test(
      'removing a player deletes generated PGN files and queues cache purge',
      () async {
        final registry = _CapturedLocalLibraryRegistry();
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          lichessPgnByUsername: const <String, String>{'alpha': _mergeGameOne},
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
          localDatabaseRegistrar: registry.registerAll,
          localDatabaseUnregistrar: registry.unregister,
          localDatabasePlayerUnregistrar: registry.unregisterPlayerWorkspace,
        );
        await notifier.load();
        await notifier.addManualPlayer('Prep Target');
        final playerId = notifier.state.players.single.id;
        await notifier.selectPlayer(playerId);
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'alpha',
        );
        final account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.lichess,
            )!;
        await notifier.syncAccount(account);

        final player = notifier.state.selectedPlayer!;
        final sourcePath =
            player.account(PlayerWorkspaceSource.lichess)!.pgnPath!;
        final combinedPath = player.combinedPgnPath!;
        final workspaceDir = Directory(
          '${temp.path}/player-workspace/${_fakeSafeFilePart(player.id)}',
        );
        final stalePath = '${workspaceDir.path}/stale-old-source.pgn';
        registry
            .registered[stalePath] = LocalLibraryEntryMetadata.playerWorkspace(
          playerId: player.id,
          playerName: player.displayName,
          gameCount: 1,
        );
        expect(await File(sourcePath).exists(), isTrue);
        expect(await File(combinedPath).exists(), isTrue);
        expect(await _count(db, 'local_chess_databases'), 2);

        await notifier.removePlayer(player.id);
        await notifier.debugDrainPlayerCleanup();

        expect(notifier.state.players, isEmpty);
        expect(await File(sourcePath).exists(), isFalse);
        expect(await File(combinedPath).exists(), isFalse);
        expect(await workspaceDir.exists(), isFalse);
        expect(registry.playerWorkspacesUnregistered, contains(player.id));
        expect(registry.registered, isEmpty);
        await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
        expect(await _count(db, 'local_chess_databases'), 0);
      },
    );

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
      'removing an account deletes its generated PGN and rebuilds combined',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          lichessPgnByUsername: const <String, String>{
            'alpha': _mergeGameOne,
            'beta': _mergeGameTwo,
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
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'alpha',
        );
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.lichess,
          username: 'beta',
        );

        for (final account in notifier.state.selectedPlayer!.accountsFor(
          PlayerWorkspaceSource.lichess,
        )) {
          await notifier.syncAccount(account);
        }

        var player = notifier.state.selectedPlayer!;
        final alpha = player
            .accountsFor(PlayerWorkspaceSource.lichess)
            .singleWhere((account) => account.username == 'alpha');
        final beta = player
            .accountsFor(PlayerWorkspaceSource.lichess)
            .singleWhere((account) => account.username == 'beta');
        final alphaPath = alpha.pgnPath!;
        final betaPath = beta.pgnPath!;
        expect(await File(alphaPath).exists(), isTrue);
        expect(await File(betaPath).exists(), isTrue);
        expect(player.combinedGameCount, 2);

        await notifier.removeAccountEntry(alpha);

        player = notifier.state.selectedPlayer!;
        expect(
          player
              .accountsFor(PlayerWorkspaceSource.lichess)
              .map((account) => account.username),
          <String>['beta'],
        );
        expect(await File(alphaPath).exists(), isFalse);
        expect(await File(betaPath).exists(), isTrue);
        expect(player.combinedGameCount, 1);
        expect(player.combinedPgnPath, isNotNull);
        final combinedGames = splitPgnGames(
          await File(player.combinedPgnPath!).readAsString(),
        );
        expect(combinedGames, hasLength(1));
        expect(combinedGames.single, contains('Lichess import 2'));
        await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
        expect(await _count(db, 'local_chess_databases'), 2);
      },
    );

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
      'sync skips local import when server source cache is unchanged',
      () async {
        final sourcePgns = <String, String>{
          'alpha': '$_mergeGameOne\n\n$_mergeGameTwo',
        };
        final workspaceRepository = _RemoteHitPlayerWorkspaceRepository(
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

        final firstPlayer = notifier.state.selectedPlayer!;
        final firstAccount =
            firstPlayer.account(PlayerWorkspaceSource.lichess)!;
        final firstLastSyncAt = firstAccount.lastSyncAtMs;
        final firstCombinedBuiltAt = firstPlayer.combinedBuiltAtMs;
        expect(firstLastSyncAt, isNotNull);
        expect(workspaceRepository.replaceExistingRequests, <bool>[true]);
        expect(await File(firstAccount.pgnPath!).exists(), isTrue);

        workspaceRepository.remoteUnchanged = true;
        account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.lichess,
            )!;
        await notifier.syncAccount(account);

        final nextPlayer = notifier.state.selectedPlayer!;
        final nextAccount = nextPlayer.account(PlayerWorkspaceSource.lichess)!;
        expect(workspaceRepository.replaceExistingRequests, hasLength(1));
        expect(nextAccount.gameCount, firstAccount.gameCount);
        expect(
          nextAccount.lastSyncAtMs,
          greaterThanOrEqualTo(firstLastSyncAt!),
        );
        expect(nextPlayer.combinedBuiltAtMs, firstCombinedBuiltAt);
      },
    );

    test('sync treats an empty incremental delta as already current', () async {
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
        localRepository: LocalChessDatabaseRepository(database: () async => db),
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
      final firstPlayer = notifier.state.selectedPlayer!;
      final firstCombinedBuiltAt = firstPlayer.combinedBuiltAtMs;
      final firstPath =
          firstPlayer.account(PlayerWorkspaceSource.lichess)!.pgnPath!;

      sourcePgns['alpha'] = '';
      account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.lichess,
          )!;
      await notifier.syncAccount(account);

      final nextPlayer = notifier.state.selectedPlayer!;
      expect(workspaceRepository.replaceExistingRequests, hasLength(1));
      expect(nextPlayer.combinedBuiltAtMs, firstCombinedBuiltAt);
      expect(splitPgnGames(await File(firstPath).readAsString()), hasLength(2));
    });

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

    test('ChessEver sync counts title-stripped no-FIDE name aliases', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository(
        root: temp,
        chessEverPgnByPlayerId: const <String, String>{
          'ce-vasif': _vasifChessEverMixedFidePgn,
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('GM Vasif Durarbayli');
      await notifier.selectPlayer(notifier.state.players.single.id);
      await notifier.connectChessEverPlayer(
        const GamebasePlayer(
          id: 'ce-vasif',
          fideId: '13402935',
          name: 'Durarbayli, Vasif',
          gender: PlayerGender.male,
          fed: 'AZE',
          title: 'GM',
        ),
      );

      final account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!;
      await notifier.syncAccount(account);

      final chessever =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!;
      expect(chessever.gameCount, 2);
      expect(chessever.availableGameCount, 2);
      expect(chessever.remainingGameCount, 0);
      expect(chessever.downloadProgress, 1.0);
    });

    test(
      'load repairs stale downloaded ChessEver stats from the source PGN',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = _StaleSourceStatsRepository(
          database: () async => db,
        );
        final path = p.join(temp.path, 'repair-chessever.pgn');
        await workspaceRepository.mergeIntoLocalDatabase(
          localRepository: localRepository,
          path: path,
          sourceLabel: 'GM Vasif Durarbayli ChessEver',
          pgn: _vasifChessEverMixedFidePgn,
          playerAliases: const <String>['Durarbayli, Vasif'],
          playerFideId: '13402935',
          replaceExisting: true,
        );
        const playerId = 'player-vasif';
        final stalePlayer = PlayerWorkspacePlayer(
          id: playerId,
          displayName: 'GM Vasif Durarbayli',
          createdAtMs: 1,
          fideId: '13402935',
          title: 'GM',
          accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
            PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
              source: PlayerWorkspaceSource.chessever,
              username: 'GM Vasif Durarbayli',
              externalId: 'ce-vasif',
              displayName: 'GM Vasif Durarbayli',
              pgnPath: path,
              lastSyncAtMs: 2,
              availableGameCount: 2,
              gameCount: 1,
            ),
          },
        );
        workspaceRepository.snapshot = PlayerWorkspaceSnapshot(
          players: <PlayerWorkspacePlayer>[stalePlayer],
          selectedPlayerId: playerId,
        );

        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: localRepository,
        );
        await notifier.load();

        final chessever =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;
        expect(chessever.gameCount, 2);
        expect(chessever.availableGameCount, 2);
        expect(chessever.remainingGameCount, 0);
        expect(chessever.downloadProgress, 1.0);
        expect(localRepository.statsRequested, isFalse);

        final repairedSnapshot = await workspaceRepository.loadSnapshot();
        expect(
          repairedSnapshot.players.single
              .account(PlayerWorkspaceSource.chessever)!
              .gameCount,
          2,
        );
      },
    );

    test(
      'load rebuilds a stale Combined index from its typed sources',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        const playerId = 'player-stale-combined';
        final sourcePath = await workspaceRepository.sourcePgnPath(
          playerId: playerId,
          playerName: 'GM Vasif Durarbayli',
          fideId: '13402935',
          source: PlayerWorkspaceSource.chessever,
        );
        await workspaceRepository.mergeIntoLocalDatabase(
          localRepository: localRepository,
          path: sourcePath,
          sourceLabel: 'GM Vasif Durarbayli ChessEver',
          pgn: _vasifGeographicChessEverPgn,
          playerAliases: const <String>['Durarbayli, Vasif'],
          playerFideId: '13402935',
          replaceExisting: true,
        );
        final combinedPath = await workspaceRepository.combinedPgnPath(
          playerId: playerId,
          playerName: 'GM Vasif Durarbayli',
          fideId: '13402935',
        );
        await File(combinedPath).writeAsString(_vasifGeographicChessEverPgn);
        expect(
          await workspaceRepository.isCombinedDatabaseCurrent(combinedPath),
          isFalse,
        );
        workspaceRepository.snapshot = PlayerWorkspaceSnapshot(
          selectedPlayerId: playerId,
          players: <PlayerWorkspacePlayer>[
            PlayerWorkspacePlayer(
              id: playerId,
              displayName: 'GM Vasif Durarbayli',
              createdAtMs: 1,
              fideId: '13402935',
              accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
                PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.chessever,
                  username: 'GM Vasif Durarbayli',
                  externalId: 'ce-vasif',
                  pgnPath: sourcePath,
                  gameCount: 2,
                ),
              },
              combinedPgnPath: combinedPath,
              combinedGameCount: 2,
              combinedBuiltAtMs: 1,
            ),
          ],
        );

        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: localRepository,
        );
        await notifier.load();

        expect(
          await workspaceRepository.isCombinedDatabaseCurrent(combinedPath),
          isTrue,
        );
        final combinedPgn = await File(combinedPath).readAsString();
        expect(
          combinedPgn,
          contains('[$playerWorkspaceCombinedSourceTag "chessever"]'),
        );
        expect(
          combinedPgn,
          contains('[$playerWorkspaceCombinedTimeControlTag "classical"]'),
        );
      },
    );

    test(
      'FIDE-locked player rejects a different ChessEver source after deletion',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();
        await notifier.addManualPlayer('GM Vasif Durarbayli');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-vasif',
            fideId: '13402935',
            name: 'Durarbayli, Vasif',
            gender: PlayerGender.male,
            fed: 'AZE',
            title: 'GM',
          ),
        );

        final source =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;
        await notifier.removeAccountEntry(source);

        var player = notifier.state.selectedPlayer!;
        expect(player.fideId, '13402935');
        expect(player.account(PlayerWorkspaceSource.chessever), isNull);

        await expectLater(
          notifier.connectChessEverPlayer(
            const GamebasePlayer(
              id: 'ce-carlsen',
              fideId: '1503014',
              name: 'Carlsen, Magnus',
              gender: PlayerGender.male,
              fed: 'NOR',
              title: 'GM',
            ),
          ),
          throwsA(
            isA<StateError>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('locked to FIDE 13402935'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('FIDE 1503014'),
                ),
          ),
        );

        player = notifier.state.selectedPlayer!;
        expect(player.fideId, '13402935');
        expect(player.account(PlayerWorkspaceSource.chessever), isNull);
        expect(player.displayName, 'GM Vasif Durarbayli');
      },
    );

    test(
      'FIDE-locked player can reconnect the same ChessEver source after deletion',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();
        await notifier.addManualPlayer('GM Vasif Durarbayli');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-vasif',
            fideId: '13402935',
            name: 'Durarbayli, Vasif',
            gender: PlayerGender.male,
            fed: 'AZE',
            title: 'GM',
          ),
        );

        final source =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;
        await notifier.removeAccountEntry(source);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-vasif-reindexed',
            fideId: '13402935',
            name: 'Durarbayli, Vasif',
            gender: PlayerGender.male,
            fed: 'AZE',
            title: 'GM',
          ),
        );

        final player = notifier.state.selectedPlayer!;
        final chessever = player.account(PlayerWorkspaceSource.chessever)!;
        expect(player.fideId, '13402935');
        expect(chessever.externalId, 'ce-vasif-reindexed');
        expect(chessever.displayName, 'GM Vasif Durarbayli');
      },
    );

    test(
      'FIDE-locked reconnect resolves exact identity and downloads immediately',
      () async {
        const reindexed = GamebasePlayer(
          id: 'ce-vasif-reindexed',
          fideId: '13402935',
          name: 'Durarbayli, Vasif',
          gender: PlayerGender.male,
          fed: 'AZE',
          title: 'GM',
        );
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          chessEverPgnByPlayerId: const <String, String>{
            'ce-vasif-reindexed': '$_mergeGameOne\n\n$_mergeGameTwo',
          },
          chessEverPlayersByFideId: const <String, GamebasePlayer>{
            '13402935': reindexed,
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
        await notifier.addManualPlayer('GM Vasif Durarbayli');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-vasif-old',
            fideId: '13402935',
            name: 'Durarbayli, Vasif',
            gender: PlayerGender.male,
            fed: 'AZE',
            title: 'GM',
          ),
        );
        final oldAccount =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;
        await notifier.removeAccountEntry(oldAccount);

        await notifier.reconnectLockedChessEverSource();

        final player = notifier.state.selectedPlayer!;
        final reconnected = player.account(PlayerWorkspaceSource.chessever)!;
        expect(workspaceRepository.chessEverFideIdRequests, ['13402935']);
        expect(reconnected.externalId, 'ce-vasif-reindexed');
        expect(reconnected.gameCount, 2);
        expect(reconnected.pgnPath, isNotNull);
        expect(player.combinedGameCount, 2);
        expect(player.combinedPgnPath, isNotNull);
      },
    );

    test(
      'FIDE-locked reconnect rejects a mismatched lookup response',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(
            root: temp,
            chessEverPlayersByFideId: const <String, GamebasePlayer>{
              '13402935': GamebasePlayer(
                id: 'ce-carlsen',
                fideId: '1503014',
                name: 'Carlsen, Magnus',
                gender: PlayerGender.male,
                fed: 'NOR',
                title: 'GM',
              ),
            },
          )
          ..snapshot = const PlayerWorkspaceSnapshot(
            selectedPlayerId: 'vasif',
            players: <PlayerWorkspacePlayer>[
              PlayerWorkspacePlayer(
                id: 'vasif',
                displayName: 'GM Vasif Durarbayli',
                createdAtMs: 1,
                fideId: '13402935',
              ),
            ],
          );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();

        await expectLater(
          notifier.reconnectLockedChessEverSource(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('locked to FIDE 13402935'),
            ),
          ),
        );
        expect(
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          ),
          isNull,
        );
        expect(notifier.state.operations, isEmpty);
      },
    );

    test(
      'FIDE-locked player rejects ChessEver refresh identity drift',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final gamebaseRepository = _FakeGamebaseRepository(
          const <String, String>{},
          playersById: const <String, GamebasePlayer>{
            'ce-vasif': GamebasePlayer(
              id: 'ce-carlsen',
              fideId: '1503014',
              name: 'Carlsen, Magnus',
              gender: PlayerGender.male,
              fed: 'NOR',
              title: 'GM',
            ),
          },
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: gamebaseRepository,
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();
        await notifier.addManualPlayer('GM Vasif Durarbayli');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-vasif',
            fideId: '13402935',
            name: 'Durarbayli, Vasif',
            gender: PlayerGender.male,
            fed: 'AZE',
            title: 'GM',
          ),
        );

        final source =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;
        await expectLater(
          notifier.refreshAccountEntry(source),
          throwsA(
            isA<StateError>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('locked to FIDE 13402935'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('FIDE 1503014'),
                ),
          ),
        );

        final player = notifier.state.selectedPlayer!;
        final chessever = player.account(PlayerWorkspaceSource.chessever)!;
        expect(player.fideId, '13402935');
        expect(player.chesseverPlayerId, 'ce-vasif');
        expect(chessever.externalId, 'ce-vasif');
        expect(chessever.displayName, 'GM Vasif Durarbayli');
        expect(chessever.error, contains('locked to FIDE 13402935'));
      },
    );

    test('combined rebuild sums FIDE and no-FIDE player sources', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository(
        root: temp,
        chessEverPgnByPlayerId: const <String, String>{
          'ce-vasif': _vasifChessEverPgn,
        },
        chessComPgnByUsername: const <String, String>{
          'vasifdurarbayli': _vasifChessComPgn,
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('GM Vasif Durarbayli');
      await notifier.selectPlayer(notifier.state.players.single.id);
      await notifier.connectChessEverPlayer(
        const GamebasePlayer(
          id: 'ce-vasif',
          fideId: '13402935',
          name: 'Durarbayli, Vasif',
          gender: PlayerGender.male,
          fed: 'AZE',
          title: 'GM',
        ),
      );
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.chesscom,
        username: 'vasifdurarbayli',
      );

      final chessever =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!;
      await notifier.syncAccount(chessever);
      final chessCom =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chesscom,
          )!;
      await notifier.syncAccount(chessCom);

      final player = notifier.state.selectedPlayer!;
      expect(player.fideId, '13402935');
      expect(player.account(PlayerWorkspaceSource.chessever)!.gameCount, 2);
      expect(player.account(PlayerWorkspaceSource.chesscom)!.gameCount, 2);
      expect(player.combinedGameCount, 4);
      expect(player.combinedPgnPath, isNotNull);
      expect(
        splitPgnGames(await File(player.combinedPgnPath!).readAsString()),
        hasLength(4),
      );
    });

    test(
      'Combined preserves source classification and resolves ECO opening names',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(
          root: temp,
          chessEverPgnByPlayerId: const <String, String>{
            'ce-vasif': _vasifGeographicChessEverPgn,
          },
          chessComPgnByUsername: const <String, String>{
            'vasifdurarbayli': _vasifClassifiedChessComPgn,
          },
        );
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: localRepository,
        );
        await notifier.load();
        await notifier.addManualPlayer('GM Vasif Durarbayli');
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-vasif',
            fideId: '13402935',
            name: 'Durarbayli, Vasif',
            gender: PlayerGender.male,
            fed: 'AZE',
            title: 'GM',
          ),
        );
        await notifier.connectExternalAccount(
          source: PlayerWorkspaceSource.chesscom,
          username: 'vasifdurarbayli',
        );

        await notifier.syncAccount(
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!,
        );
        await notifier.syncAccount(
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chesscom,
          )!,
        );

        final player = notifier.state.selectedPlayer!;
        final combinedPath = player.combinedPgnPath!;
        final statsRepository = PlayerStatsRepository(database: () async => db);
        final all = await statsRepository.computePlayerStats(
          databasePath: combinedPath,
          aliases: const <String>[
            'GM Vasif Durarbayli',
            'Durarbayli, Vasif',
            'vasifdurarbayli',
          ],
          playerFideId: '13402935',
        );
        final classical = await statsRepository.computePlayerStats(
          databasePath: combinedPath,
          aliases: const <String>[
            'GM Vasif Durarbayli',
            'Durarbayli, Vasif',
            'vasifdurarbayli',
          ],
          playerFideId: '13402935',
          timeControlCategory: 'classical',
        );

        expect(player.combinedGameCount, 4);
        expect(all.games, 4);
        expect(classical.games, 2);
        expect(classical.overall.wins, 1);
        expect(classical.overall.draws, 1);
        expect(classical.ratingSeries.map((spot) => spot.rating), [2600, 2605]);
        expect(
          {
            for (final source in all.years.single.sources)
              source.label: source.count,
          },
          <String, int>{'ChessEver': 2, 'Chess.com': 2},
        );
        expect({
          for (final opening in all.openings) opening.eco: opening.name,
        }, containsPair('C02', 'French: Advance'));
        expect({
          for (final opening in all.openings) opening.eco: opening.name,
        }, containsPair('B20', 'Sicilian Defense'));
        expect({
          for (final opening in all.openings) opening.eco: opening.name,
        }, containsPair('C45', 'Scotch Game'));
        expect(
          all.openings.map((opening) => opening.name),
          isNot(contains(anyOf(isNull, startsWith('Unknown')))),
        );

        final classicalPage = await localRepository.localDatabaseGamesPage(
          databasePath: combinedPath,
          filter: LocalChessGameFilter(timeControlCategory: 'classical'),
          playerFideId: '13402935',
          playerAliases: const <String>['Durarbayli, Vasif'],
          sortBy: LocalChessGameSortField.date,
          sortDirection: LocalChessGameSortDirection.desc,
          pageNumber: 0,
          pageSize: 50,
        );
        expect(classicalPage, isNotNull);
        expect(classicalPage!.totalCount, 2);
        expect(
          classicalPage.games.map(
            (game) => game.game.metadata['Date']?.toString(),
          ),
          <String>['2025.02.02', '2025.01.01'],
        );

        final openingSearch = await localRepository.localDatabaseGamesPage(
          databasePath: combinedPath,
          search: 'French Advance',
          playerFideId: '13402935',
          playerAliases: const <String>['Durarbayli, Vasif'],
          sortBy: LocalChessGameSortField.opening,
          sortDirection: LocalChessGameSortDirection.asc,
          pageNumber: 0,
          pageSize: 50,
        );
        expect(openingSearch, isNotNull);
        expect(openingSearch!.totalCount, 1);
        expect(openingSearch.games.single.game.metadata['ECO'], 'C02');

        final openingSort = await localRepository.localDatabaseGamesPage(
          databasePath: combinedPath,
          sortBy: LocalChessGameSortField.opening,
          sortDirection: LocalChessGameSortDirection.asc,
          pageNumber: 0,
          pageSize: 50,
        );
        expect(
          openingSort!.games.map(
            (game) => game.game.metadata['Opening']?.toString(),
          ),
          <String>[
            'French: Advance',
            'Modern Defense',
            'Scotch Game',
            'Sicilian Defense',
          ],
        );
      },
    );

    test('ChessEver sync replaces the single source snapshot', () async {
      final sourcePgns = <String, String>{
        'ce-carlsen': '$_mergeGameOne\n\n$_mergeGameTwo',
      };
      final workspaceRepository = _FakePlayerWorkspaceRepository(
        root: temp,
        chessEverPgnByPlayerId: sourcePgns,
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Prep Target');
      await notifier.selectPlayer(notifier.state.players.single.id);
      await notifier.connectChessEverPlayer(
        const GamebasePlayer(
          id: 'ce-carlsen',
          fideId: '1503014',
          name: 'Carlsen, Magnus',
          gender: PlayerGender.male,
          fed: 'NOR',
          title: 'GM',
        ),
      );

      var account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!;
      await notifier.syncAccount(account);
      final firstPath =
          notifier.state.selectedPlayer!
              .account(PlayerWorkspaceSource.chessever)!
              .pgnPath!;

      sourcePgns['ce-carlsen'] = _mergeGameThree;
      account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!;
      await notifier.syncAccount(account);

      final chessever =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!;
      expect(chessever.pgnPath, firstPath);
      expect(workspaceRepository.replaceExistingRequests.last, isTrue);
      final games = splitPgnGames(await File(firstPath).readAsString());
      expect(games, hasLength(1));
      expect(games.single, contains('Lichess import 3'));
    });

    test(
      'ChessEver sync progress hides technical repository wording',
      () async {
        final workspaceRepository = _HoldingChessEverWorkspaceRepository(
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
        await notifier.selectPlayer(notifier.state.players.single.id);
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

        final syncFuture = notifier.syncAccount(account);
        await workspaceRepository.downloadStarted.future.timeout(
          const Duration(seconds: 5),
        );

        final operation = notifier.state.operations.values.singleWhere(
          (item) => item.source == PlayerWorkspaceSource.chessever,
        );
        expect(operation.message, 'Downloading ChessEver games...');
        expect(operation.message.toLowerCase(), isNot(contains('hydrat')));
        expect(operation.message.toLowerCase(), isNot(contains('pgn')));
        expect(operation.percent, 20);

        workspaceRepository.finishDownload();
        await syncFuture.timeout(const Duration(seconds: 5));
      },
    );

    test('Chess.com source-cache wait stays indeterminate', () async {
      final workspaceRepository = _HoldingChessComSnapshotWorkspaceRepository(
        root: temp,
        chessComPgnByUsername: const <String, String>{
          'durarbayli': _mergeGameOne,
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('GM Vasif Durarbayli');
      await notifier.selectPlayer(notifier.state.players.single.id);
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.chesscom,
        username: 'durarbayli',
      );
      final account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chesscom,
          )!;

      final syncFuture = notifier.syncAccount(account);
      await workspaceRepository.downloadStarted.future.timeout(
        const Duration(seconds: 5),
      );

      final operation = notifier.state.operations.values.singleWhere(
        (item) => item.source == PlayerWorkspaceSource.chesscom,
      );
      expect(operation.message, 'Checking Chess.com source cache...');
      expect(operation.percent, isNull);

      workspaceRepository.finishDownload();
      await syncFuture.timeout(const Duration(seconds: 5));
    });

    test(
      'ChessEver page transitions keep stable text and full download progress',
      () async {
        final workspaceRepository = _SequencedChessEverWorkspaceRepository(
          root: temp,
          chessEverPgnByPlayerId: const <String, String>{
            'ce-carlsen': '$_mergeGameOne\n\n$_mergeGameTwo',
          },
          progress: const <({String message, double? progress})>[
            (
              message: 'ChessEver: 995/1000 ready on page 1...',
              progress: 0.995,
            ),
            (
              message:
                  'ChessEver: loading page 2 '
                  '(1000 games per request)...',
              progress: null,
            ),
          ],
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

        final syncFuture = notifier.syncAccount(account);
        await workspaceRepository.downloadStarted.future.timeout(
          const Duration(seconds: 5),
        );

        final operation = notifier.state.operations.values.singleWhere(
          (item) => item.source == PlayerWorkspaceSource.chessever,
        );
        expect(operation.message, 'Downloading ChessEver games...');
        expect(operation.message, isNot(contains('requesting next batch')));
        expect(operation.message, isNot(contains('Loading')));
        expect(operation.percent, 40);

        workspaceRepository.finishDownload();
        await syncFuture.timeout(const Duration(seconds: 5));
      },
    );

    test(
      'ChessEver sync shows import phase after download completes',
      () async {
        final workspaceRepository = _HoldingImportChessEverWorkspaceRepository(
          root: temp,
          chessEverPgnByPlayerId: const <String, String>{
            'ce-carlsen': _mergeGameOne,
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
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-carlsen',
            fideId: '1503014',
            name: 'Carlsen, Magnus',
            gender: PlayerGender.male,
            fed: 'NOR',
            title: 'GM',
          ),
        );
        final account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;

        final syncFuture = notifier.syncAccount(account);
        await workspaceRepository.importStarted.future.timeout(
          const Duration(seconds: 5),
        );

        final operation = notifier.state.operations.values.singleWhere(
          (item) => item.source == PlayerWorkspaceSource.chessever,
        );
        expect(operation.message, 'Importing ChessEver games...');
        expect(operation.percent, 40);

        workspaceRepository.finishImport();
        await syncFuture.timeout(const Duration(seconds: 5));
        expect(notifier.state.operations, isEmpty);
      },
    );

    test('canceling a running ChessEver sync clears it for retry', () async {
      final workspaceRepository = _HoldingChessEverWorkspaceRepository(
        root: temp,
        chessEverPgnByPlayerId: const <String, String>{
          'ce-carlsen': '$_mergeGameOne\n\n$_mergeGameTwo',
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('Prep Target');
      await notifier.selectPlayer(notifier.state.players.single.id);
      await notifier.connectChessEverPlayer(
        const GamebasePlayer(
          id: 'ce-carlsen',
          fideId: '1503014',
          name: 'Carlsen, Magnus',
          gender: PlayerGender.male,
          fed: 'NOR',
          title: 'GM',
        ),
      );
      final account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chessever,
          )!;

      final syncFuture = notifier.syncAccount(account);
      await workspaceRepository.downloadStarted.future.timeout(
        const Duration(seconds: 5),
      );
      expect(notifier.state.operations, isNotEmpty);

      await notifier.cancelAccountOperation(account);
      await syncFuture.timeout(const Duration(seconds: 5));
      expect(notifier.state.operations, isEmpty);
      expect(
        notifier.state.selectedPlayer!
            .account(PlayerWorkspaceSource.chessever)!
            .gameCount,
        0,
      );

      final retryFuture = notifier.syncAccount(account);
      workspaceRepository.finishDownload();
      await retryFuture.timeout(const Duration(seconds: 5));
      expect(notifier.state.operations, isEmpty);
      expect(
        notifier.state.selectedPlayer!
            .account(PlayerWorkspaceSource.chessever)!
            .gameCount,
        2,
      );
    });

    test(
      'stale progress from a canceled ChessEver sync cannot resurrect or clear retry',
      () async {
        final workspaceRepository = _StaleProgressChessEverWorkspaceRepository(
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
        await notifier.selectPlayer(notifier.state.players.single.id);
        await notifier.connectChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-carlsen',
            fideId: '1503014',
            name: 'Carlsen, Magnus',
            gender: PlayerGender.male,
            fed: 'NOR',
            title: 'GM',
          ),
        );
        final account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;

        final firstSync = notifier.syncAccount(account);
        await workspaceRepository.firstDownloadStarted.future.timeout(
          const Duration(seconds: 5),
        );
        await notifier.cancelAccountOperation(
          account,
          timeout: const Duration(milliseconds: 1),
        );
        await workspaceRepository.staleProgressSent.future.timeout(
          const Duration(seconds: 5),
        );
        expect(notifier.state.operations, isEmpty);

        final retrySync = notifier.syncAccount(account);
        await workspaceRepository.secondDownloadStarted.future.timeout(
          const Duration(seconds: 5),
        );
        expect(notifier.state.operations, isNotEmpty);

        workspaceRepository.finishCanceledDownload();
        await firstSync.timeout(const Duration(seconds: 5));
        expect(notifier.state.operations, isNotEmpty);

        workspaceRepository.finishRetryDownload();
        await retrySync.timeout(const Duration(seconds: 5));
        expect(notifier.state.operations, isEmpty);
        expect(
          notifier.state.selectedPlayer!
              .account(PlayerWorkspaceSource.chessever)!
              .gameCount,
          2,
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
      final localRepository = LocalChessDatabaseRepository(
        database: () async => db,
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: localRepository,
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
      expect(player.fideId, isNull);
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

      final filtered = await localRepository.localDatabaseGamesPage(
        databasePath: player.combinedPgnPath!,
        search: 'Opponent',
        filter: LocalChessGameFilter(
          playerOutcome: LocalPlayerOutcomeFilter.win,
        ),
        playerAliases: const <String>['Prep Target', 'DrNykterstein'],
        sortBy: LocalChessGameSortField.date,
        sortDirection: LocalChessGameSortDirection.desc,
        pageNumber: 0,
        pageSize: 50,
      );
      expect(filtered, isNotNull);
      expect(filtered!.totalCount, 1);
      expect(filtered.games.single.game.metadata['White'], 'DrNykterstein');

      final tree = await localRepository.rebuildOpeningTreeFromCachedGames(
        databasePath: player.combinedPgnPath!,
      );
      expect(tree, isNotNull);
      expect(tree!.index.downloadedGameCount, 2);
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

    test('concurrent source syncs coalesce combined rebuilds', () async {
      final workspaceRepository = _CoalescingPlayerWorkspaceRepository(
        root: temp,
        lichessPgnByUsername: const <String, String>{
          'durarbayli': _mergeGameOne,
        },
        chessComPgnByUsername: const <String, String>{
          'durarbayli': _mergeGameThree,
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('GM Vasif Durarbayli');
      final playerId = notifier.state.players.single.id;
      await notifier.selectPlayer(playerId);
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.lichess,
        username: 'durarbayli',
      );
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.chesscom,
        username: 'durarbayli',
      );

      final player = notifier.state.selectedPlayer!;
      final lichess = player.account(PlayerWorkspaceSource.lichess)!;
      final chessCom = player.account(PlayerWorkspaceSource.chesscom)!;
      final syncs = Future.wait(<Future<void>>[
        notifier.syncAccount(lichess),
        notifier.syncAccount(chessCom),
      ]);
      await workspaceRepository.downloadsStarted.future.timeout(
        const Duration(seconds: 5),
      );
      workspaceRepository.finishDownloads();
      await syncs.timeout(const Duration(seconds: 5));

      expect(workspaceRepository.mergeCalls, 2);
      expect(workspaceRepository.combinedRebuildCalls, 1);
      expect(notifier.state.selectedPlayer!.combinedGameCount, 2);
    });

    test('combined rebuild waits for active source imports', () async {
      final workspaceRepository = _HoldingMergePlayerWorkspaceRepository(
        root: temp,
        lichessPgnByUsername: const <String, String>{
          'durarbayli': _mergeGameOne,
        },
        chessComPgnByUsername: const <String, String>{
          'durarbayli': _mergeGameThree,
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();
      await notifier.addManualPlayer('GM Vasif Durarbayli');
      final playerId = notifier.state.players.single.id;
      await notifier.selectPlayer(playerId);
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.lichess,
        username: 'durarbayli',
      );
      await notifier.connectExternalAccount(
        source: PlayerWorkspaceSource.chesscom,
        username: 'durarbayli',
      );

      final player = notifier.state.selectedPlayer!;
      final lichess = player.account(PlayerWorkspaceSource.lichess)!;
      final chessCom = player.account(PlayerWorkspaceSource.chesscom)!;
      final syncs = Future.wait(<Future<void>>[
        notifier.syncAccount(lichess),
        notifier.syncAccount(chessCom),
      ]);
      await workspaceRepository.allMergesStarted.future.timeout(
        const Duration(seconds: 5),
      );

      expect(workspaceRepository.combinedRebuildCalls, 0);
      workspaceRepository.finishMerges();
      await syncs.timeout(const Duration(seconds: 5));

      expect(workspaceRepository.mergeCalls, 2);
      expect(workspaceRepository.combinedRebuildCalls, 1);
      expect(workspaceRepository.combinedStartedDuringMerge, isFalse);
    });

    test(
      'deleting player during source sync cancels without resurrecting',
      () async {
        final workspaceRepository = _HoldingChessEverWorkspaceRepository(
          root: temp,
          chessEverPgnByPlayerId: const <String, String>{
            'ce-player': _mergeGameOne,
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
        await notifier.addChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-player',
            fideId: '13402935',
            name: 'Durarbayli, Vasif',
            gender: PlayerGender.male,
            fed: 'AZE',
            title: 'GM',
          ),
        );
        final playerId = notifier.state.players.single.id;
        await notifier.selectPlayer(playerId);
        final account =
            notifier.state.selectedPlayer!.account(
              PlayerWorkspaceSource.chessever,
            )!;

        final sync = notifier.syncAccount(account);
        await workspaceRepository.downloadStarted.future.timeout(
          const Duration(seconds: 5),
        );

        await notifier.removePlayer(playerId);
        workspaceRepository.finishDownload();
        await sync.timeout(const Duration(seconds: 5));
        await notifier.debugDrainPlayerCleanup();

        expect(notifier.state.players, isEmpty);
        expect(workspaceRepository.snapshot.players, isEmpty);
        expect(notifier.state.operations, isEmpty);
      },
    );

    test(
      'addChessEverPlayer reuses FIDE identity and ChessEver id fallback',
      () async {
        final workspaceRepository =
            _FakePlayerWorkspaceRepository()
              ..snapshot = const PlayerWorkspaceSnapshot(
                players: [
                  PlayerWorkspacePlayer(
                    id: 'fide-owner',
                    displayName: 'GM Existing FIDE Player',
                    createdAtMs: 2,
                    fideId: '1503014',
                    chesseverPlayerId: 'ce-before-reindex',
                    accounts: {
                      PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
                        source: PlayerWorkspaceSource.chessever,
                        username: 'Existing FIDE Player',
                        externalId: 'ce-before-reindex',
                      ),
                    },
                  ),
                  PlayerWorkspacePlayer(
                    id: 'chessever-owner',
                    displayName: 'Existing No-FIDE Player',
                    createdAtMs: 1,
                    fideId: '?',
                    chesseverPlayerId: 'ce-stable-id',
                    accounts: {
                      PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
                        source: PlayerWorkspaceSource.chessever,
                        username: 'Existing No-FIDE Player',
                        externalId: 'ce-stable-id',
                      ),
                    },
                  ),
                ],
              );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();

        final fideOwnerId = await notifier.addChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-after-reindex',
            fideId: '1503014',
            name: 'Player, Existing FIDE',
            gender: PlayerGender.male,
            fed: 'NOR',
            title: 'GM',
          ),
        );
        final chessEverOwnerId = await notifier.addChessEverPlayer(
          const GamebasePlayer(
            id: 'ce-stable-id',
            fideId: '?',
            name: 'Player, Existing No-FIDE',
            gender: PlayerGender.male,
            fed: 'USA',
          ),
        );

        expect(fideOwnerId, 'fide-owner');
        expect(chessEverOwnerId, 'chessever-owner');
        expect(notifier.state.players, hasLength(2));
        expect(notifier.state.selectedPlayerId, 'chessever-owner');
        expect(workspaceRepository.snapshot.players, hasLength(2));
        expect(
          notifier.state.players
              .singleWhere((player) => player.id == 'fide-owner')
              .chesseverPlayerId,
          'ce-before-reindex',
        );
      },
    );

    test(
      'ensurePlayerWorkspaceByFideId attaches ChessEver to a FIDE-only player',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(
            chessEverPlayersByFideId: const <String, GamebasePlayer>{
              '1503014': GamebasePlayer(
                id: 'ce-carlsen',
                fideId: '1503014',
                name: 'Carlsen, Magnus',
                gender: PlayerGender.male,
                fed: 'NOR',
                title: 'GM',
              ),
            },
          )
          ..snapshot = const PlayerWorkspaceSnapshot(
            players: <PlayerWorkspacePlayer>[
              PlayerWorkspacePlayer(
                id: 'fide-only',
                displayName: 'Magnus Carlsen',
                createdAtMs: 1,
                fideId: '1503014',
              ),
            ],
          );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();

        final playerId = await notifier.ensurePlayerWorkspaceByFideId(
          '1503014',
        );

        expect(playerId, 'fide-only');
        expect(notifier.state.players, hasLength(1));
        expect(notifier.state.selectedPlayerId, 'fide-only');
        expect(workspaceRepository.chessEverFideIdRequests, <String>[
          '1503014',
        ]);
        final player = notifier.state.selectedPlayer!;
        expect(player.fideId, '1503014');
        expect(
          player.account(PlayerWorkspaceSource.chessever)?.externalId,
          'ce-carlsen',
        );
      },
    );

    test('addManualPlayer returns the created player id', () async {
      final workspaceRepository = _FakePlayerWorkspaceRepository();
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();

      final id = await notifier.addManualPlayer('Prep Target');

      expect(id, isNotEmpty);
      expect(notifier.state.players.single.id, id);
    });

    test(
      'attachFetchedAccounts appends several usernames per platform',
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
        final playerId = await notifier.addManualPlayer('Prep Target');
        await notifier.selectPlayer(playerId);

        final added = await notifier.attachFetchedAccounts(const [
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'firstLichess',
            displayName: 'First',
          ),
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'secondLichess',
            displayName: 'Second',
          ),
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chesscom,
            username: 'thirdChessCom',
            displayName: 'Third',
          ),
        ]);

        expect(added, 3);

        final player = notifier.state.selectedPlayer!;
        expect(
          player
              .accountsFor(PlayerWorkspaceSource.lichess)
              .map((account) => account.username),
          <String>['firstLichess', 'secondLichess'],
        );
        expect(
          player.accountsFor(PlayerWorkspaceSource.chesscom).single.username,
          'thirdChessCom',
        );
        // The extra username lands in the persisted snapshot too.
        expect(
          workspaceRepository.snapshot.players.single.accountsFor(
            PlayerWorkspaceSource.lichess,
          ),
          hasLength(2),
        );
      },
    );

    test(
      'attachFetchedAccounts counts only genuinely new identity keys',
      () async {
        final workspaceRepository =
            _FakePlayerWorkspaceRepository()
              ..snapshot = const PlayerWorkspaceSnapshot(
                selectedPlayerId: 'target',
                players: [
                  PlayerWorkspacePlayer(
                    id: 'target',
                    displayName: 'Prep Target',
                    createdAtMs: 1,
                    accounts: {
                      PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                        source: PlayerWorkspaceSource.lichess,
                        username: 'Alpha',
                      ),
                      PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
                        source: PlayerWorkspaceSource.chesscom,
                        username: 'OldHandle',
                        externalId: 'chess-account-42',
                      ),
                    },
                  ),
                ],
              );
        final notifier = PlayerWorkspaceNotifier(
          workspaceRepository: workspaceRepository,
          gamebaseRepository: GamebaseRepository(Dio()),
          localRepository: LocalChessDatabaseRepository(
            database: () async => db,
          ),
        );
        await notifier.load();

        final added = await notifier.attachFetchedAccounts(const [
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'alpha',
          ),
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chesscom,
            username: 'RenamedHandle',
            externalId: 'chess-account-42',
          ),
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'Beta',
          ),
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'beta',
          ),
        ]);

        expect(added, 1);
        final player = notifier.state.selectedPlayer!;
        expect(
          player
              .accountsFor(PlayerWorkspaceSource.lichess)
              .map((account) => account.username),
          <String>['Alpha', 'Beta'],
        );
        expect(
          player.accountsFor(PlayerWorkspaceSource.chesscom).single.username,
          'OldHandle',
        );
        expect(
          workspaceRepository.snapshot.players.single.allAccounts,
          hasLength(3),
        );
      },
    );

    for (final source in const <PlayerWorkspaceSource>[
      PlayerWorkspaceSource.lichess,
      PlayerWorkspaceSource.chesscom,
    ]) {
      test(
        '${source.label} identity cannot move to another player workspace',
        () async {
          final ownerAccount = PlayerWorkspaceAccount(
            source: source,
            username:
                source == PlayerWorkspaceSource.lichess
                    ? 'SharedHandle'
                    : 'PreviousHandle',
            externalId:
                source == PlayerWorkspaceSource.chesscom
                    ? 'shared-account-id'
                    : null,
          );
          final fetchedAccount = PlayerWorkspaceAccount(
            source: source,
            username:
                source == PlayerWorkspaceSource.lichess
                    ? 'sharedhandle'
                    : 'CurrentHandle',
            externalId:
                source == PlayerWorkspaceSource.chesscom
                    ? 'shared-account-id'
                    : null,
          );
          final workspaceRepository =
              _FakePlayerWorkspaceRepository()
                ..snapshot = PlayerWorkspaceSnapshot(
                  selectedPlayerId: 'target',
                  players: [
                    PlayerWorkspacePlayer(
                      id: 'owner',
                      displayName: 'GM Existing Owner',
                      createdAtMs: 2,
                      fideId: '1503014',
                      accounts: {source: ownerAccount},
                    ),
                    const PlayerWorkspacePlayer(
                      id: 'target',
                      displayName: 'New Target',
                      createdAtMs: 1,
                    ),
                  ],
                );
          final notifier = PlayerWorkspaceNotifier(
            workspaceRepository: workspaceRepository,
            gamebaseRepository: GamebaseRepository(Dio()),
            localRepository: LocalChessDatabaseRepository(
              database: () async => db,
            ),
          );
          await notifier.load();

          await expectLater(
            notifier.attachFetchedAccounts([fetchedAccount]),
            throwsA(
              isA<StateError>()
                  .having(
                    (error) => error.message.toString(),
                    'message',
                    contains(source.label),
                  )
                  .having(
                    (error) => error.message.toString(),
                    'message',
                    contains('GM Existing Owner'),
                  )
                  .having(
                    (error) => error.message.toString(),
                    'message',
                    contains('FIDE 1503014'),
                  ),
            ),
          );

          expect(notifier.state.selectedPlayer!.allAccounts, isEmpty);
          expect(
            workspaceRepository.snapshot.players
                .singleWhere((player) => player.id == 'target')
                .allAccounts,
            isEmpty,
          );
        },
      );
    }

    test(
      'attachFetchedAccounts is a no-op without a selected player',
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
        // Deliberately not selected.

        final added = await notifier.attachFetchedAccounts(const [
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'orphan',
          ),
        ]);

        expect(added, 0);
        expect(
          notifier.state.players.single.accountsFor(
            PlayerWorkspaceSource.lichess,
          ),
          isEmpty,
        );
      },
    );
  });

  group('Player workspace local import', () {
    test(
      'reports save progress without materializing the Player source cache',
      () async {
        final pgnFile = File(p.join(temp.path, 'progress-source.pgn'));
        final workspaceRepository = PlayerWorkspaceRepository(
          supportDirectory: () async => temp,
        );
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        final progress = <({String message, double? progress})>[];

        await workspaceRepository.mergeIntoLocalDatabase(
          localRepository: localRepository,
          path: pgnFile.path,
          sourceLabel: 'Progress Source',
          pgn: '$_mergeGameOne\n\n$_mergeGameTwo',
          playerAliases: const <String>['Carlsen, Magnus'],
          replaceExisting: true,
          onProgress:
              (message, value) =>
                  progress.add((message: message, progress: value)),
        );

        expect(
          progress.map((item) => item.message),
          anyElement(startsWith('Saving downloaded PGN')),
        );
        expect(
          progress.map((item) => item.message),
          contains('Downloaded PGN saved.'),
        );
        expect(
          progress.map((item) => item.message),
          contains('Finalizing Progress Source...'),
        );
        final fractions =
            progress.map((item) => item.progress).whereType<double>().toList();
        expect(fractions, isNotEmpty);
        expect(fractions.first, 0.0);
        expect(fractions, contains(0.08));
        expect(fractions.last, greaterThanOrEqualTo(0.99));
        expect(await _count(db, 'local_chess_games'), 0);
      },
    );

    test('merges downloaded PGNs without duplicating source games', () async {
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
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
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
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
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
      expect(await _count(db, 'local_chess_games'), 0);
      expect(splitPgnGames(await File(path).readAsString()), hasLength(3));
    });

    test(
      'preserves repeated PGN games while keeping sync idempotent',
      () async {
        final workspaceRepository = PlayerWorkspaceRepository();
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        final path = '${temp.path}/workspace/repeated-games.pgn';

        final first = await workspaceRepository.mergeIntoLocalDatabase(
          localRepository: localRepository,
          path: path,
          sourceLabel: 'Repeated source',
          pgn: '$_mergeGameOne\n\n$_mergeGameOne',
          playerAliases: const <String>['DrNykterstein'],
        );
        expect(first.stats.gameCount, 2);
        expect(splitPgnGames(await File(path).readAsString()), hasLength(2));

        final unchanged = await workspaceRepository.mergeIntoLocalDatabase(
          localRepository: localRepository,
          path: path,
          sourceLabel: 'Repeated source',
          pgn: '$_mergeGameOne\n\n$_mergeGameOne',
          playerAliases: const <String>['DrNykterstein'],
        );
        expect(unchanged.stats.gameCount, 2);
        expect(unchanged.stats.newGameCount, 0);

        final oneMore = await workspaceRepository.mergeIntoLocalDatabase(
          localRepository: localRepository,
          path: path,
          sourceLabel: 'Repeated source',
          pgn: '$_mergeGameOne\n\n$_mergeGameOne\n\n$_mergeGameOne',
          playerAliases: const <String>['DrNykterstein'],
        );
        expect(oneMore.stats.gameCount, 3);
        expect(oneMore.stats.newGameCount, 1);
        expect(splitPgnGames(await File(path).readAsString()), hasLength(3));
      },
    );

    test('reads the latest sync date directly from the Player PGN', () async {
      final workspaceRepository = PlayerWorkspaceRepository();
      final file = File('${temp.path}/latest-player-date.pgn');
      await file.writeAsString('''
[Event "Older"]
[Date "2024.03.05"]

1. e4 e5 1/2-1/2

[Event "Newest"]
[Date "2026.07.14"]

1. d4 d5 1/2-1/2
''');

      expect(
        await workspaceRepository.latestPgnGameDate(file.path),
        DateTime.utc(2026, 7, 14),
      );
      expect(
        await workspaceRepository.latestPgnGameDate('${temp.path}/missing.pgn'),
        isNull,
      );
    });

    test(
      'combined rebuild streams source files by real PGN boundaries',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        final sourceA = File('${temp.path}/source-a.pgn');
        final sourceB = File('${temp.path}/source-b.pgn');
        await sourceA.writeAsString('''
[Event "Comment trap"]
[Site "Local"]
[Date "2026.07.07"]
[Round "1"]
[White "DrNykterstein"]
[Black "Opponent"]
[Result "1-0"]

1. e4 {
[Event "This is a comment, not a game"]
} e5 2. Nf3 Nc6 1-0
''');
        await sourceB.writeAsString('''
$_mergeGameOne

$_mergeGameOne
''');

        final result = await workspaceRepository.rebuildCombinedDatabase(
          localRepository: localRepository,
          playerId: 'stream-player',
          playerName: 'DrNykterstein',
          sourcePaths: <String>[sourceA.path, sourceB.path],
          playerAliases: const <String>['DrNykterstein'],
        );

        expect(result.stats.gameCount, 3);
        expect(result.stats.newGameCount, 3);
        expect(await _count(db, 'local_chess_games'), 0);
        final combined = await File(result.path).readAsString();
        expect(combined, contains('This is a comment, not a game'));
        expect(combined, contains('Lichess import 1'));
      },
    );

    test(
      'Combined rebuild does not materialize a second legacy cache',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        final chessEver = File('${temp.path}/indexed-chessever.pgn');
        final lichess = File('${temp.path}/indexed-lichess.pgn');
        await chessEver.writeAsString(_mergeGameOne);
        await lichess.writeAsString(_mergeGameTwo);
        await localRepository.importSingleFileSource(path: chessEver.path);
        await localRepository.importSingleFileSource(path: lichess.path);

        final result = await workspaceRepository.rebuildCombinedDatabase(
          localRepository: localRepository,
          playerId: 'indexed-combined',
          playerName: 'DrNykterstein',
          sourcePaths: <String>[chessEver.path, lichess.path],
          sources: <PlayerWorkspaceCombinedSource>[
            PlayerWorkspaceCombinedSource(
              path: chessEver.path,
              source: PlayerWorkspaceSource.chessever,
            ),
            PlayerWorkspaceCombinedSource(
              path: lichess.path,
              source: PlayerWorkspaceSource.lichess,
            ),
          ],
          playerAliases: const <String>['DrNykterstein'],
        );

        expect(result.source, isNull);
        expect(result.stats.gameCount, 2);
        expect(await _count(db, 'local_chess_games'), 2);
        expect(
          splitPgnGames(await File(result.path).readAsString()),
          hasLength(2),
        );
      },
    );

    test(
      'Combined rebuild preserves equivalent games across sources',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        final chessEver = File('${temp.path}/chessever-dedupe.pgn');
        final lichess = File('${temp.path}/lichess-dedupe.pgn');
        await chessEver.writeAsString(_crossSourceCanonicalGame);
        await lichess.writeAsString(
          '$_crossSourceEquivalentGame\n\n$_mergeGameThree',
        );
        await localRepository.importSingleFileSource(path: chessEver.path);
        await localRepository.importSingleFileSource(path: lichess.path);
        final progress = <({String message, double? fraction})>[];

        final result = await workspaceRepository.rebuildCombinedDatabase(
          localRepository: localRepository,
          playerId: 'cross-source-overlap',
          playerName: 'DrNykterstein',
          sourcePaths: <String>[chessEver.path, lichess.path],
          sources: <PlayerWorkspaceCombinedSource>[
            // Deliberately reversed: output follows the visible source rail,
            // not incidental map/insertion order.
            PlayerWorkspaceCombinedSource(
              path: lichess.path,
              source: PlayerWorkspaceSource.lichess,
            ),
            PlayerWorkspaceCombinedSource(
              path: chessEver.path,
              source: PlayerWorkspaceSource.chessever,
            ),
          ],
          playerAliases: const <String>['DrNykterstein'],
          onProgress:
              (message, fraction) =>
                  progress.add((message: message, fraction: fraction)),
        );

        final games = splitPgnGames(await File(result.path).readAsString());
        expect(result.source, isNull);
        expect(games, hasLength(3));
        expect(result.stats.gameCount, 3);
        // Combined remains a PGN; only the explicitly imported source rows are
        // present in the legacy cache.
        expect(await _count(db, 'local_chess_games'), 3);
        expect(
          games.first,
          contains('[$playerWorkspaceCombinedSourceTag "chessever"]'),
        );
        expect(
          games.where(
            (game) =>
                game.contains('[$playerWorkspaceCombinedSourceTag "lichess"]'),
          ),
          hasLength(2),
        );
        for (final game in games) {
          expect(
            RegExp(
              RegExp.escape('[$playerWorkspaceCombinedVersionTag '),
            ).allMatches(game),
            hasLength(1),
          );
          expect(
            RegExp(
              RegExp.escape('[$playerWorkspaceCombinedSourceTag '),
            ).allMatches(game),
            hasLength(1),
          );
        }
        expect(
          progress.where(
            (item) => item.message.startsWith('Combining source '),
          ),
          isNotEmpty,
        );
        final preparationFractions = progress
            .where((item) => item.message.startsWith('Combining source '))
            .map((item) => item.fraction)
            .whereType<double>()
            .toList(growable: false);
        expect(preparationFractions.toSet().length, greaterThanOrEqualTo(3));
        expect(
          preparationFractions,
          orderedEquals(<double>[...preparationFractions]..sort()),
        );
        expect(preparationFractions.last, 0.10);
      },
    );

    test(
      'Combined preparation failure preserves the previous database',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        const playerId = 'failure-safe-combined';
        final combinedPath = await workspaceRepository.combinedPgnPath(
          playerId: playerId,
          playerName: 'DrNykterstein',
        );
        const previous = '[Event "Last good Combined"]\n\n1. e4 1-0\n';
        await File(combinedPath).writeAsString(previous);
        final validSource = File('${temp.path}/valid-before-failure.pgn');
        await validSource.writeAsString(_mergeGameOne);

        await expectLater(
          workspaceRepository.rebuildCombinedDatabase(
            localRepository: localRepository,
            playerId: playerId,
            playerName: 'DrNykterstein',
            sourcePaths: <String>[
              validSource.path,
              '${temp.path}/missing-source.pgn',
            ],
            playerAliases: const <String>['DrNykterstein'],
          ),
          throwsA(anything),
        );

        expect(await File(combinedPath).readAsString(), previous);
      },
    );

    test(
      'canceling Combined preparation preserves output and removes temp files',
      () async {
        final workspaceRepository = _FakePlayerWorkspaceRepository(root: temp);
        final localRepository = LocalChessDatabaseRepository(
          database: () async => db,
        );
        const playerId = 'cancel-safe-combined';
        final combinedPath = await workspaceRepository.combinedPgnPath(
          playerId: playerId,
          playerName: 'DrNykterstein',
        );
        const previous = '[Event "Last good Combined"]\n\n1. d4 1-0\n';
        await File(combinedPath).writeAsString(previous);
        final source = File('${temp.path}/cancel-source.pgn');
        await source.writeAsString(_largeChessEverPgn(1000));
        final token = OperationCancellationToken();

        await expectLater(
          workspaceRepository.rebuildCombinedDatabase(
            localRepository: localRepository,
            playerId: playerId,
            playerName: 'DrNykterstein',
            sourcePaths: <String>[source.path],
            playerAliases: const <String>['DrNykterstein'],
            cancellationToken: token,
            onProgress: (message, _) {
              if (message.startsWith('Combining source ')) token.cancel();
            },
          ),
          throwsA(isA<OperationCanceledException>()),
        );

        expect(await File(combinedPath).readAsString(), previous);
        final leftovers =
            await File(combinedPath).parent
                .list()
                .where(
                  (entity) => p
                      .basename(entity.path)
                      .startsWith('${p.basename(combinedPath)}.tmp-'),
                )
                .toList();
        expect(leftovers, isEmpty);
      },
    );

    test(
      'source save computes stats without waiting for the legacy cache',
      () async {
        final workspaceRepository = PlayerWorkspaceRepository(
          importStatsTimeout: const Duration(milliseconds: 10),
        );
        final localRepository = _HangingStatsLocalChessDatabaseRepository(
          database: () async => db,
        );
        final path = '${temp.path}/workspace/stats-hang.pgn';

        final result = await workspaceRepository
            .mergeIntoLocalDatabase(
              localRepository: localRepository,
              path: path,
              sourceLabel: 'Prep Target ChessEver',
              pgn: '$_mergeGameOne\n\n$_mergeGameTwo',
              playerAliases: const <String>['DrNykterstein'],
              replaceExisting: true,
            )
            .timeout(const Duration(seconds: 5));

        expect(result.stats.gameCount, 2);
        expect(result.stats.newGameCount, 2);
        expect(result.stats.winCount, 1);
        expect(result.stats.drawCount, 0);
        expect(result.stats.lossCount, 1);
        expect(localRepository.statsRequested, isFalse);
      },
    );

    test('source save never opens the shared app cache', () async {
      final workspaceRepository = PlayerWorkspaceRepository();
      var pathResolverUsed = false;
      var sharedAppCacheRequested = false;
      final localRepository = LocalChessDatabaseRepository(
        database: () async {
          sharedAppCacheRequested = true;
          throw StateError('shared app cache should not be opened');
        },
        databaseFilePath: () async {
          pathResolverUsed = true;
          return '${temp.path}/local_chess.db';
        },
      );
      final path = '${temp.path}/workspace/chessever-vasif.pgn';

      final result = await workspaceRepository
          .mergeIntoLocalDatabase(
            localRepository: localRepository,
            path: path,
            sourceLabel: 'GM Vasif Durarbayli ChessEver',
            pgn: '$_mergeGameOne\n\n$_mergeGameTwo',
            playerAliases: const <String>['DrNykterstein'],
            playerFideId: '1503014',
            replaceExisting: true,
          )
          .timeout(const Duration(seconds: 2));

      expect(result.stats.gameCount, 2);
      expect(result.stats.newGameCount, 2);
      expect(pathResolverUsed, isFalse);
      expect(sharedAppCacheRequested, isFalse);
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_games'), 0);
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
    test(
      'external Gamebase PGN request forwards cursor and delta header',
      () async {
        RequestOptions? request;
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              request = options;
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  data: _mergeGameThree,
                  statusCode: 200,
                  headers: Headers.fromMap(<String, List<String>>{
                    'x-game-count': <String>['1'],
                    'x-pgn-cache': <String>['refresh'],
                    'x-pgn-snapshot': <String>['delta'],
                  }),
                ),
              );
            },
          ),
        );
        final repository = GamebaseRepository(
          dio,
          baseUrl: 'https://gamebase.test',
        );

        final export = await repository.getExternalPlayerGamesPgn(
          source: GamebaseExternalPlayerSource.lichess,
          username: 'DrNykterstein',
          sinceMs: 1782864000000,
          receiveTimeout: const Duration(seconds: 12),
        );

        expect(
          request?.uri.path,
          '/api/player/lichess/DrNykterstein/games.pgn',
        );
        expect(request?.queryParameters['since'], 1782864000000);
        expect(request?.receiveTimeout, const Duration(seconds: 12));
        expect(export?.gameCount, 1);
        expect(export?.cacheStatus, 'refresh');
        expect(export?.snapshotStatus, 'delta');
      },
    );

    test(
      'fails clearly when the ChessEver PGN export is unavailable',
      () async {
        final gamebaseRepository = _FakeGamebaseRepository(
          const <String, String>{'ce-1': _mergeGameOne, 'ce-2': _mergeGameTwo},
        );
        final workspaceRepository = PlayerWorkspaceRepository();

        await expectLater(
          workspaceRepository.downloadChessEverGames(
            repository: gamebaseRepository,
            playerId: 'ce-player',
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('PGN export is unavailable'),
            ),
          ),
        );

        expect(gamebaseRepository.exportPlayerIds, <String>['ce-player']);
        expect(gamebaseRepository.requestedPlayerIds, isEmpty);
        expect(gamebaseRepository.hydratedIds, isEmpty);
      },
    );

    test('uses the player PGN export without loading live pages', () async {
      final gamebaseRepository = _FakeGamebaseRepository(
        const <String, String>{},
        pgnExport: '$_mergeGameOne\n\n$_mergeGameTwo\n',
        playerGamesError: StateError('live endpoint must not be called'),
      );
      final progressMessages = <String>[];
      final workspaceRepository = PlayerWorkspaceRepository();

      final downloaded = await workspaceRepository.downloadChessEverGames(
        repository: gamebaseRepository,
        playerId: 'ce-player',
        fideId: '1503014',
        sinceDate: DateTime.utc(2026, 6, 2),
        onProgress: (message, _) => progressMessages.add(message),
      );

      expect(downloaded.source, PlayerWorkspaceSource.chessever);
      expect(downloaded.gameCount, 2);
      expect(downloaded.pgn, contains('Lichess import 1'));
      expect(downloaded.pgn, contains('Lichess import 2'));
      expect(downloaded.replaceExistingSource, isTrue);
      expect(gamebaseRepository.exportPlayerIds, <String>['ce-player']);
      expect(gamebaseRepository.exportFideIds, <String?>['1503014']);
      expect(gamebaseRepository.exportDateFrom, <String?>[null]);
      expect(gamebaseRepository.requestedPlayerIds, isEmpty);
      expect(gamebaseRepository.requestedIncludeData, isEmpty);
      expect(gamebaseRepository.requestedPageSizes, isEmpty);
      expect(gamebaseRepository.requestedDateFrom, isEmpty);
      expect(gamebaseRepository.hydratedIds, isEmpty);
      expect(
        progressMessages,
        contains('ChessEver: downloaded 2 games as PGN.'),
      );
    });

    test(
      'accepts the compact PGN snapshot without a hidden count fallback',
      () async {
        final gamebaseRepository = _FakeGamebaseRepository(
          const <String, String>{'ce-1': _mergeGameOne, 'ce-2': _mergeGameTwo},
          pgnExport: _mergeGameOne,
        );
        final workspaceRepository = PlayerWorkspaceRepository();

        final downloaded = await workspaceRepository.downloadChessEverGames(
          repository: gamebaseRepository,
          playerId: 'ce-player',
          sinceDate: DateTime.utc(2026, 3, 31),
          expectedGameCount: 2,
        );

        expect(downloaded.gameCount, 1);
        expect(downloaded.pgn, contains('Lichess import 1'));
        expect(downloaded.pgn, isNot(contains('Lichess import 2')));
        expect(downloaded.replaceExistingSource, isTrue);
        expect(gamebaseRepository.exportPlayerIds, <String>['ce-player']);
        expect(gamebaseRepository.exportDateFrom, <String?>[null]);
        expect(gamebaseRepository.requestedPlayerIds, isEmpty);
        expect(gamebaseRepository.hydratedIds, isEmpty);
      },
    );

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
            expect(request.url.queryParameters, isNot(contains('clocks')));
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

    test('downloads external source games from gamebase snapshots', () async {
      var directClientRequests = 0;
      final gamebaseRepository = _FakeGamebaseRepository(
        const <String, String>{},
        externalExports:
            const <GamebaseExternalPlayerSource, GamebasePlayerPgnExport>{
              GamebaseExternalPlayerSource.lichess: GamebasePlayerPgnExport(
                pgn: _mergeGameOne,
                gameCount: 1,
                cacheStatus: 'miss',
                snapshotStatus: 'delta',
              ),
              GamebaseExternalPlayerSource.chesscom: GamebasePlayerPgnExport(
                pgn: _mergeGameTwo,
                gameCount: 1,
                cacheStatus: 'hit',
              ),
            },
      );
      final workspaceRepository = PlayerWorkspaceRepository(
        gamebaseRepository: gamebaseRepository,
        client: MockClient((_) async {
          directClientRequests += 1;
          throw StateError('direct origin should not be used');
        }),
      );

      final lichess = await workspaceRepository.downloadLichessGames(
        username: 'DrNykterstein',
        sinceMs: 1782864000000,
      );
      final chessComProgress = <({String message, double? progress})>[];
      final chessCom = await workspaceRepository.downloadChessComGames(
        username: 'Hikaru',
        onProgress:
            (message, progress) =>
                chessComProgress.add((message: message, progress: progress)),
      );

      expect(lichess.source, PlayerWorkspaceSource.lichess);
      expect(lichess.pgn, _mergeGameOne);
      expect(lichess.replaceExistingSource, isFalse);
      expect(lichess.remoteUnchanged, isFalse);
      expect(chessCom.source, PlayerWorkspaceSource.chesscom);
      expect(chessCom.pgn, _mergeGameTwo);
      expect(chessCom.replaceExistingSource, isTrue);
      expect(chessCom.remoteUnchanged, isTrue);
      expect(chessComProgress.first.message, contains('source cache'));
      expect(chessComProgress.first.progress, isNull);
      expect(gamebaseRepository.externalSinceMs, <int?>[1782864000000, null]);
      expect(gamebaseRepository.externalReceiveTimeouts, <Duration?>[
        const Duration(seconds: 3),
        const Duration(seconds: 12),
      ]);
      expect(directClientRequests, 0);
    });

    test(
      'falls back from a 503 source service to one direct Lichess stream',
      () async {
        DioException serviceUnavailable() {
          final options = RequestOptions(
            path: '/api/player/lichess/DrNykterstein/games.pgn',
          );
          return DioException(
            requestOptions: options,
            response: Response<void>(requestOptions: options, statusCode: 503),
            type: DioExceptionType.badResponse,
          );
        }

        final gamebaseRepository = _FakeGamebaseRepository(
          const <String, String>{},
          externalErrors: <Object>[serviceUnavailable()],
        );
        var directRequests = 0;
        final waits = <Duration>[];
        final progressUpdates = <({String message, double? progress})>[];
        final workspaceRepository = PlayerWorkspaceRepository(
          gamebaseRepository: gamebaseRepository,
          client: MockClient((request) async {
            directRequests += 1;
            expect(request.url.host, 'lichess.org');
            expect(request.url.path, '/api/games/user/DrNykterstein');
            return http.Response(_mergeGameOne, 200);
          }),
          retryWait: (delay, cancellationToken) async {
            cancellationToken?.throwIfCanceled();
            waits.add(delay);
          },
        );

        final downloaded = await workspaceRepository.downloadLichessGames(
          username: 'DrNykterstein',
          expectedGameCount: 2,
          onProgress:
              (message, progress) => progressUpdates.add((
                message: message,
                progress: progress,
              )),
        );

        expect(gamebaseRepository.externalRequestCount, 1);
        expect(waits, isEmpty);
        expect(directRequests, 1);
        expect(downloaded.gameCount, 1);
        expect(downloaded.pgn, contains('Lichess import 1'));
        expect(
          progressUpdates.map((update) => update.message),
          anyElement(contains('Downloading directly from Lichess')),
        );
        expect(progressUpdates.first.progress, isNull);
        expect(
          gamebaseRepository.externalReceiveTimeouts,
          <Duration?>[const Duration(seconds: 3)],
        );
      },
    );

    test(
      'falls back from a 504 source service to direct Chess.com archives',
      () async {
        final options = RequestOptions(
          path: '/api/player/chesscom/Hikaru/games.pgn',
        );
        final gamebaseRepository = _FakeGamebaseRepository(
          const <String, String>{},
          externalErrors: <Object>[
            DioException(
              requestOptions: options,
              response: Response<void>(
                requestOptions: options,
                statusCode: 504,
              ),
              type: DioExceptionType.badResponse,
            ),
          ],
        );
        final requestedPaths = <String>[];
        final progressMessages = <String>[];
        final workspaceRepository = PlayerWorkspaceRepository(
          gamebaseRepository: gamebaseRepository,
          client: MockClient((request) async {
            requestedPaths.add(request.url.path);
            if (request.url.path == '/pub/player/hikaru/games/archives') {
              return http.Response(
                jsonEncode({
                  'archives': [
                    'https://api.chess.com/pub/player/hikaru/games/2026/07',
                  ],
                }),
                200,
              );
            }
            expect(request.url.path, '/pub/player/hikaru/games/2026/07/pgn');
            return http.Response(_mergeGameOne, 200);
          }),
        );

        final downloaded = await workspaceRepository.downloadChessComGames(
          username: 'Hikaru',
          onProgress: (message, _) => progressMessages.add(message),
        );

        expect(gamebaseRepository.externalRequestCount, 1);
        expect(gamebaseRepository.externalReceiveTimeouts, <Duration?>[
          const Duration(seconds: 12),
        ]);
        expect(requestedPaths, <String>[
          '/pub/player/hikaru/games/archives',
          '/pub/player/hikaru/games/2026/07/pgn',
        ]);
        expect(downloaded.gameCount, 1);
        expect(downloaded.pgn, contains('Lichess import 1'));
        expect(
          progressMessages,
          anyElement(contains('Downloading directly from Chess.com')),
        );
      },
    );

    test('empty Gamebase delta is reported as already current', () async {
      final gamebaseRepository = _FakeGamebaseRepository(
        const <String, String>{},
        externalExports:
            const <GamebaseExternalPlayerSource, GamebasePlayerPgnExport>{
              GamebaseExternalPlayerSource.lichess: GamebasePlayerPgnExport(
                pgn: '',
                gameCount: 0,
                cacheStatus: 'refresh',
                snapshotStatus: 'delta',
              ),
            },
      );
      final workspaceRepository = PlayerWorkspaceRepository(
        gamebaseRepository: gamebaseRepository,
      );

      final downloaded = await workspaceRepository.downloadLichessGames(
        username: 'DrNykterstein',
        sinceMs: 1782864000000,
      );

      expect(downloaded.gameCount, 0);
      expect(downloaded.pgn, isEmpty);
      expect(downloaded.replaceExistingSource, isFalse);
      expect(downloaded.remoteUnchanged, isTrue);
    });

    test(
      'gamebase-configured source downloads do not fall back to client origins',
      () async {
        var directClientRequests = 0;
        final gamebaseRepository = _FakeGamebaseRepository(
          const <String, String>{},
        );
        final workspaceRepository = PlayerWorkspaceRepository(
          gamebaseRepository: gamebaseRepository,
          client: MockClient((_) async {
            directClientRequests += 1;
            throw StateError('direct origin should not be used');
          }),
        );

        await expectLater(
          workspaceRepository.downloadLichessGames(username: 'DrNykterstein'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          workspaceRepository.downloadChessComGames(username: 'Hikaru'),
          throwsA(isA<StateError>()),
        );

        expect(directClientRequests, 0);
      },
    );

    test('large Lichess downloads use one streaming request', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      var requests = 0;
      final progressMessages = <String>[];
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.host, 'lichess.org');
          expect(request.url.path, '/api/games/user/durarbayli');
          expect(request.url.queryParameters, isNot(contains('since')));
          expect(request.url.queryParameters, isNot(contains('until')));
          expect(request.headers['Accept'], 'application/x-chess-pgn');
          requests += 1;
          inFlight += 1;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          inFlight -= 1;
          return http.Response(_mergeGameOne, 200);
        }),
      );

      final downloaded = await workspaceRepository.downloadLichessGames(
        username: 'durarbayli',
        expectedGameCount: 6107,
        onProgress: (message, _) => progressMessages.add(message),
      );

      expect(downloaded.gameCount, 1);
      expect(downloaded.pgn, contains('Lichess import 1'));
      expect(downloaded.replaceExistingSource, isTrue);
      expect(requests, 1);
      expect(maxInFlight, 1);
      expect(progressMessages, isNot(anyElement(contains('date ranges'))));
    });

    test('retries a direct Lichess 503 before succeeding', () async {
      var requests = 0;
      final waits = <Duration>[];
      final progressMessages = <String>[];
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((_) async {
          requests += 1;
          if (requests == 1) return http.Response('unavailable', 503);
          return http.Response(_mergeGameOne, 200);
        }),
        retryWait: (delay, cancellationToken) async {
          cancellationToken?.throwIfCanceled();
          waits.add(delay);
        },
      );

      final downloaded = await workspaceRepository.downloadLichessGames(
        username: 'DrNykterstein',
        expectedGameCount: 2,
        onProgress: (message, _) => progressMessages.add(message),
      );

      expect(requests, 2);
      expect(waits, const <Duration>[Duration(seconds: 2)]);
      expect(downloaded.gameCount, 1);
      expect(downloaded.pgn, contains('Lichess import 1'));
      expect(
        progressMessages,
        anyElement(contains('temporarily unavailable. Retrying in 2 seconds')),
      );
    });

    test('waits a full minute before retrying a Lichess 429', () async {
      var requests = 0;
      final waits = <Duration>[];
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((_) async {
          requests += 1;
          if (requests == 1) {
            return http.Response(
              'too many requests',
              429,
              headers: const <String, String>{'retry-after': '5'},
            );
          }
          return http.Response(_mergeGameOne, 200);
        }),
        retryWait: (delay, cancellationToken) async {
          cancellationToken?.throwIfCanceled();
          waits.add(delay);
        },
      );

      final downloaded = await workspaceRepository.downloadLichessGames(
        username: 'DrNykterstein',
      );

      expect(requests, 2);
      expect(waits, const <Duration>[Duration(minutes: 1)]);
      expect(downloaded.gameCount, 1);
    });

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
      expect(progressUpdates.first.progress, isNull);
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

    test('downloads Chess.com monthly archives serially', () async {
      final requestedPaths = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      final workspaceRepository = PlayerWorkspaceRepository(
        client: MockClient((request) async {
          requestedPaths.add(request.url.path);
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
          inFlight += 1;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          inFlight -= 1;
          return http.Response(switch (path) {
            '/pub/player/hikaru/games/2026/05/pgn' => _mergeGameOne,
            '/pub/player/hikaru/games/2026/06/pgn' => _mergeGameTwo,
            '/pub/player/hikaru/games/2026/07/pgn' => _mergeGameThree,
            _ => throw StateError('Unexpected path $path'),
          }, 200);
        }),
      );

      final progressUpdates = <({String message, double? progress})>[];
      final downloaded = await workspaceRepository.downloadChessComGames(
        username: 'Hikaru',
        onProgress:
            (message, progress) =>
                progressUpdates.add((message: message, progress: progress)),
      );

      expect(maxInFlight, 1);
      expect(requestedPaths, <String>[
        '/pub/player/hikaru/games/archives',
        '/pub/player/hikaru/games/2026/05/pgn',
        '/pub/player/hikaru/games/2026/06/pgn',
        '/pub/player/hikaru/games/2026/07/pgn',
      ]);
      expect(downloaded.gameCount, 3);
      expect(
        downloaded.pgn.indexOf('Lichess import 1'),
        lessThan(downloaded.pgn.indexOf('Lichess import 2')),
      );
      expect(
        downloaded.pgn.indexOf('Lichess import 2'),
        lessThan(downloaded.pgn.indexOf('Lichess import 3')),
      );
      expect(progressUpdates.first.progress, isNull);
      expect(
        progressUpdates.map((update) => update.progress).whereType<double>(),
        contains(1.0),
      );
    });
  });
}

String _largeChessEverPgn(int gameCount) {
  final buffer = StringBuffer();
  for (var index = 0; index < gameCount; index++) {
    if (index > 0) buffer.writeln();
    final day = (index % 28) + 1;
    final result = index.isEven ? '1-0' : '0-1';
    buffer
      ..writeln('[Event "ChessEver cold game $index"]')
      ..writeln('[Site "ChessEver"]')
      ..writeln('[Date "2025.01.${day.toString().padLeft(2, '0')}"]')
      ..writeln('[Round "${index + 1}"]')
      ..writeln('[White "Durarbayli,Vasif"]')
      ..writeln('[Black "Opponent $index"]')
      ..writeln('[WhiteFideId "13402935"]')
      ..writeln('[BlackFideId "${20000000 + index}"]')
      ..writeln('[WhiteElo "2600"]')
      ..writeln('[BlackElo "2500"]')
      ..writeln('[Result "$result"]')
      ..writeln()
      ..writeln('1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 $result');
  }
  return buffer.toString();
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

const String _crossSourceCanonicalGame = '''
[Event "Canonical cross-source game"]
[Site "Local"]
[Date "2026.07.11"]
[Round "1"]
[White "DrNykterstein"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. O-O Nf6 5. Re1 1-0
''';

const String _crossSourceEquivalentGame = '''
[Black "Opponent"]
[White "DrNykterstein"]
[Round "1"]
[Date "2026.07.11"]
[Site "Local"]
[Event "Canonical cross-source game"]
[Result "1-0"]

1. e4 {same game from another source} e5 2. Nf3 (2. Bc4) Nc6
3. Bc4 Bc5 4. 0-0 Nf6 5. Re1+ 1-0
''';

const String _vasifChessEverPgn = '''
[Event "ChessEver FIDE source 1"]
[Site "ChessEver"]
[Date "2026.04.01"]
[White "Durarbayli,V"]
[Black "Nakamura,Hi"]
[WhiteFideId "13402935"]
[BlackFideId "2016192"]
[Result "1-0"]

1. e4 e5 1-0

[Event "ChessEver FIDE source 2"]
[Site "ChessEver"]
[Date "2026.04.02"]
[White "Nakamura,Hi"]
[Black "Durarbayli,Vasif"]
[WhiteFideId "2016192"]
[BlackFideId "13402935"]
[Result "0-1"]

1. d4 d5 0-1
''';

const String _vasifChessEverMixedFidePgn = '''
[Event "ChessEver FIDE source 1"]
[Site "ChessEver"]
[Date "2026.04.01"]
[White "Durarbayli,V"]
[Black "Nakamura,Hi"]
[WhiteFideId "13402935"]
[BlackFideId "2016192"]
[Result "1-0"]

1. e4 e5 1-0

[Event "ChessEver no-FIDE source 2"]
[Site "ChessEver"]
[Date "2026.04.02"]
[White "Nakamura,Hi"]
[Black "Durarbayli, Vasif"]
[Result "0-1"]

1. d4 d5 0-1
''';

const String _vasifChessComPgn = '''
[Event "Chess.com no-FIDE source 1"]
[Site "Chess.com"]
[Date "2026.04.03"]
[White "Vasif_Durarbayli"]
[Black "Carlsen, Magnus"]
[Result "1/2-1/2"]

1. c4 c5 1/2-1/2

[Event "Chess.com no-FIDE source 2"]
[Site "Chess.com"]
[Date "2026.04.04"]
[White "Carlsen, Magnus"]
[Black "VasifDurarbayli"]
[Result "0-1"]

1. Nf3 d5 0-1
''';

const String _vasifGeographicChessEverPgn = '''
[Event "Baku Open"]
[Site "Baku, Azerbaijan"]
[Date "2025.01.01"]
[White "Durarbayli, Vasif"]
[Black "Opponent, One"]
[WhiteFideId "13402935"]
[BlackFideId "10000001"]
[WhiteElo "2600"]
[BlackElo "2500"]
[ECO "C02"]
[Result "1-0"]

1. e4 e6 2. d4 d5 3. e5 1-0

[Event "Baku Masters"]
[Site "Baku, Azerbaijan"]
[Date "2025.02.02"]
[White "Opponent, Two"]
[Black "Durarbayli, Vasif"]
[WhiteFideId "10000002"]
[BlackFideId "13402935"]
[WhiteElo "2510"]
[BlackElo "2605"]
[ECO "B20"]
[Result "1/2-1/2"]

1. e4 c5 2. Nf3 1/2-1/2
''';

const String _vasifClassifiedChessComPgn = '''
[Event "Live Chess"]
[Site "https://www.chess.com/game/live/1"]
[Date "2025.03.03"]
[White "Vasif_Durarbayli"]
[Black "Opponent Three"]
[WhiteElo "2700"]
[BlackElo "2650"]
[TimeControl "300+0"]
[ECO "C45"]
[Result "0-1"]

1. e4 e5 2. Nf3 Nc6 3. d4 0-1

[Event "Live Chess"]
[Site "https://www.chess.com/game/live/2"]
[Date "2025.04.04"]
[White "Opponent Four"]
[Black "Vasif_Durarbayli"]
[WhiteElo "2660"]
[BlackElo "2710"]
[TimeControl "300+0"]
[ECO "B06"]
[Result "0-1"]

1. e4 g6 2. d4 Bg7 0-1
''';

class _HangingStatsLocalChessDatabaseRepository
    extends LocalChessDatabaseRepository {
  _HangingStatsLocalChessDatabaseRepository({required super.database})
    : super(cachedFileNodeGamePreviewLimit: 1);

  bool statsRequested = false;

  @override
  Future<LocalChessDatabaseResultStats> localDatabaseResultStats({
    required String databasePath,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool preferDirectDatabase = false,
  }) {
    statsRequested = true;
    return Completer<LocalChessDatabaseResultStats>().future;
  }
}

class _StaleSourceStatsRepository extends LocalChessDatabaseRepository {
  _StaleSourceStatsRepository({required super.database});

  bool statsRequested = false;

  @override
  Future<LocalChessDatabaseResultStats> localDatabaseResultStats({
    required String databasePath,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool preferDirectDatabase = false,
  }) async {
    statsRequested = true;
    return const LocalChessDatabaseResultStats(
      gameCount: 1,
      winCount: 1,
      drawCount: 0,
      lossCount: 0,
    );
  }
}

class _PartialSourceUnionStatsRepository extends LocalChessDatabaseRepository {
  _PartialSourceUnionStatsRepository({required super.database});

  var combinedPathRequests = 0;
  var sourceUnionRequests = 0;

  @override
  Future<LocalChessDatabaseResultStats> localDatabaseResultStats({
    required String databasePath,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool preferDirectDatabase = false,
  }) async {
    final lower = p.basename(databasePath).toLowerCase();
    if (lower.contains('combined')) {
      combinedPathRequests++;
      return const LocalChessDatabaseResultStats(
        gameCount: 20226,
        winCount: 11237,
        drawCount: 2011,
        lossCount: 6978,
      );
    }
    final count = switch (lower) {
      String value when value.contains('chessever') => 3982,
      String value when value.contains('lichess') => 6016,
      String value when value.contains('chesscom') => 10573,
      _ => 1,
    };
    return LocalChessDatabaseResultStats(
      gameCount: count,
      winCount: count,
      drawCount: 0,
      lossCount: 0,
    );
  }

  @override
  Future<LocalChessDatabaseResultStats> resultStatsForDatabases({
    required Iterable<String> databasePaths,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool preferDirectDatabase = false,
  }) async {
    sourceUnionRequests++;
    return const LocalChessDatabaseResultStats(
      gameCount: 9998,
      winCount: 5628,
      drawCount: 1122,
      lossCount: 3248,
    );
  }
}

/// Local repository whose consolidated cache purge blocks on [gate], so a test
/// can observe the notifier's in-flight removing state before the purge
/// finishes. Emits one progress event before blocking to prove the progress
/// plumbing reaches the removing indicator.
class _BlockingPurgeLocalRepository extends LocalChessDatabaseRepository {
  _BlockingPurgeLocalRepository(resqlite.Database db, this.gate)
    : super(database: (() async => db));

  final Completer<void> gate;
  int purgeCalls = 0;
  int? requestedBatchSize;

  @override
  Future<int> deleteCachedSourcesAwaitingPurge({
    required Iterable<String> sourcePaths,
    int batchSize = 4096,
    bool cleanupOrphanMetadata = false,
    bool checkpoint = false,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    purgeCalls += 1;
    requestedBatchSize = batchSize;
    onProgress?.call(
      LocalChessScanProgress(fraction: 0.5, message: 'Deleting games…'),
    );
    await gate.future;
    onProgress?.call(
      LocalChessScanProgress(fraction: 1, message: 'Delete complete.'),
    );
    return sourcePaths.length;
  }
}

class _FakePlayerWorkspaceRepository extends PlayerWorkspaceRepository {
  _FakePlayerWorkspaceRepository({
    Directory? root,
    this.chessEverPgnByPlayerId = const <String, String>{},
    this.chessEverPlayersByFideId = const <String, GamebasePlayer>{},
    this.lichessPgnByUsername = const <String, String>{},
    this.chessComPgnByUsername = const <String, String>{},
    this.loadGate,
  }) : root = root ?? Directory.systemTemp,
       super(supportDirectory: () async => root ?? Directory.systemTemp);

  final Directory root;
  final Map<String, String> chessEverPgnByPlayerId;
  final Map<String, GamebasePlayer> chessEverPlayersByFideId;
  final Map<String, String> lichessPgnByUsername;
  final Map<String, String> chessComPgnByUsername;
  final Completer<void>? loadGate;
  PlayerWorkspaceSnapshot snapshot = const PlayerWorkspaceSnapshot();
  final lichessSinceMsRequests = <int?>[];
  final chessComSinceMsRequests = <int?>[];
  final chessEverSinceDateRequests = <DateTime?>[];
  final chessEverFideIdRequests = <String>[];
  final replaceExistingRequests = <bool>[];
  int _counter = 0;

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async {
    await loadGate?.future;
    return snapshot;
  }

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }

  @override
  Future<GamebasePlayer?> findChessEverPlayerByFideId(
    GamebaseRepository repository,
    String fideId,
  ) async {
    chessEverFideIdRequests.add(fideId);
    return chessEverPlayersByFideId[fideId.trim()];
  }

  @override
  Future<String> sourcePgnPath({
    required String playerId,
    String? playerName,
    String? fideId,
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
  Future<String> combinedPgnPath({
    required String playerId,
    String? playerName,
    String? fideId,
  }) async {
    final dir = Directory(
      '${root.path}/player-workspace/${_fakeSafeFilePart(playerId)}',
    );
    await dir.create(recursive: true);
    return '${dir.path}/combined.pgn';
  }

  @override
  Future<bool> deletePlayerWorkspaceDirectory(String playerId) async {
    final dir = Directory(
      '${root.path}/player-workspace/${_fakeSafeFilePart(playerId)}',
    );
    if (!await dir.exists()) return false;
    await dir.delete(recursive: true);
    return true;
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
    OperationCancellationToken? cancellationToken,
  }) async {
    lichessSinceMsRequests.add(sinceMs);
    final pgn = lichessPgnByUsername[username.trim()] ?? '';
    onProgress?.call('Downloading Lichess games...', null);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.lichess,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
      remoteUnchanged: pgn.trim().isEmpty,
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
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
    String? fideId,
    DateTime? sinceDate,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    chessEverSinceDateRequests.add(sinceDate);
    final pgn = chessEverPgnByPlayerId[playerId] ?? '';
    onProgress?.call('Downloading ChessEver games...', null);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
      replaceExistingSource: true,
    );
  }

  @override
  Future<PlayerWorkspaceImportResult> mergeIntoLocalDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String path,
    required String sourceLabel,
    required String pgn,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) {
    replaceExistingRequests.add(replaceExisting);
    return super.mergeIntoLocalDatabase(
      localRepository: localRepository,
      path: path,
      sourceLabel: sourceLabel,
      pgn: pgn,
      playerAliases: playerAliases,
      playerFideId: playerFideId,
      replaceExisting: replaceExisting,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
  }
}

class _CoalescingPlayerWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _CoalescingPlayerWorkspaceRepository({
    required super.root,
    required super.lichessPgnByUsername,
    required super.chessComPgnByUsername,
  });

  final downloadsStarted = Completer<void>();
  final _finishDownloads = Completer<void>();
  var _lichessStarted = false;
  var _chessComStarted = false;
  var mergeCalls = 0;
  var combinedRebuildCalls = 0;

  void finishDownloads() {
    if (!_finishDownloads.isCompleted) _finishDownloads.complete();
  }

  void _markStarted(PlayerWorkspaceSource source) {
    switch (source) {
      case PlayerWorkspaceSource.lichess:
        _lichessStarted = true;
      case PlayerWorkspaceSource.chesscom:
        _chessComStarted = true;
      case PlayerWorkspaceSource.chessever:
      case PlayerWorkspaceSource.manual:
      case PlayerWorkspaceSource.combined:
        break;
    }
    if (_lichessStarted && _chessComStarted && !downloadsStarted.isCompleted) {
      downloadsStarted.complete();
    }
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    lichessSinceMsRequests.add(sinceMs);
    _markStarted(PlayerWorkspaceSource.lichess);
    onProgress?.call('Receiving Lichess games: 1 of about 1...', 1);
    await _finishDownloads.future;
    final pgn = lichessPgnByUsername[username.trim()] ?? '';
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
    OperationCancellationToken? cancellationToken,
  }) async {
    chessComSinceMsRequests.add(sinceMs);
    _markStarted(PlayerWorkspaceSource.chesscom);
    onProgress?.call('Chess.com: 1/1 archives done; 1 games received...', 1);
    await _finishDownloads.future;
    final pgn = chessComPgnByUsername[username.trim().toLowerCase()] ?? '';
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chesscom,
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
    String? playerFideId,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    mergeCalls += 1;
    onProgress?.call('Importing $sourceLabel games...', 1);
    return PlayerWorkspaceImportResult(
      path: path,
      stats: PlayerWorkspaceImportStats(
        gameCount: splitPgnGames(pgn).length,
        newGameCount: splitPgnGames(pgn).length,
      ),
    );
  }

  @override
  Future<PlayerWorkspaceImportResult> rebuildCombinedDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String playerId,
    required String playerName,
    String? playerFideId,
    required Iterable<String> sourcePaths,
    Iterable<PlayerWorkspaceCombinedSource> sources =
        const <PlayerWorkspaceCombinedSource>[],
    required Iterable<String> playerAliases,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    combinedRebuildCalls += 1;
    onProgress?.call('Combining and deduplicating games...', 1);
    return const PlayerWorkspaceImportResult(
      path: '/tmp/coalesced-combined.pgn',
      stats: PlayerWorkspaceImportStats(gameCount: 2),
    );
  }
}

class _RemoteHitPlayerWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _RemoteHitPlayerWorkspaceRepository({
    required super.root,
    required super.lichessPgnByUsername,
  });

  var remoteUnchanged = false;

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final pgn = lichessPgnByUsername[username.trim()] ?? '';
    onProgress?.call('Lichess: source cache checked.', 1);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.lichess,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
      replaceExistingSource: true,
      remoteUnchanged: remoteUnchanged,
    );
  }
}

class _HoldingMergePlayerWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _HoldingMergePlayerWorkspaceRepository({
    required super.root,
    required super.lichessPgnByUsername,
    required super.chessComPgnByUsername,
  });

  final allMergesStarted = Completer<void>();
  final _finishMerges = Completer<void>();
  var mergeCalls = 0;
  var combinedRebuildCalls = 0;
  var _activeMerges = 0;
  var combinedStartedDuringMerge = false;

  void finishMerges() {
    if (!_finishMerges.isCompleted) _finishMerges.complete();
  }

  @override
  Future<PlayerWorkspaceImportResult> mergeIntoLocalDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String path,
    required String sourceLabel,
    required String pgn,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    mergeCalls += 1;
    _activeMerges += 1;
    onProgress?.call('Importing $sourceLabel games...', 0.5);
    if (mergeCalls == 2 && !allMergesStarted.isCompleted) {
      allMergesStarted.complete();
    }
    await _finishMerges.future;
    _activeMerges -= 1;
    return PlayerWorkspaceImportResult(
      path: path,
      stats: PlayerWorkspaceImportStats(
        gameCount: splitPgnGames(pgn).length,
        newGameCount: splitPgnGames(pgn).length,
      ),
    );
  }

  @override
  Future<PlayerWorkspaceImportResult> rebuildCombinedDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String playerId,
    required String playerName,
    String? playerFideId,
    required Iterable<String> sourcePaths,
    Iterable<PlayerWorkspaceCombinedSource> sources =
        const <PlayerWorkspaceCombinedSource>[],
    required Iterable<String> playerAliases,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    combinedRebuildCalls += 1;
    if (_activeMerges > 0) combinedStartedDuringMerge = true;
    onProgress?.call('Combining and deduplicating games...', 1);
    return const PlayerWorkspaceImportResult(
      path: '/tmp/holding-merge-combined.pgn',
      stats: PlayerWorkspaceImportStats(gameCount: 2),
    );
  }
}

class _HoldingChessEverWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _HoldingChessEverWorkspaceRepository({
    required super.root,
    required super.chessEverPgnByPlayerId,
  });

  final downloadStarted = Completer<void>();
  final _finishDownload = Completer<void>();

  void finishDownload() {
    if (!_finishDownload.isCompleted) _finishDownload.complete();
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessEverGames({
    required GamebaseRepository repository,
    required String playerId,
    String? fideId,
    DateTime? sinceDate,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    chessEverSinceDateRequests.add(sinceDate);
    onProgress?.call(
      'ChessEver: 0/2 PGNs embedded; hydrating 2 missing PGNs (2 at a time)...',
      0.5,
    );
    if (!downloadStarted.isCompleted) downloadStarted.complete();
    if (cancellationToken == null) {
      await _finishDownload.future;
    } else {
      await Future.any<void>(<Future<void>>[
        _finishDownload.future,
        cancellationToken.whenCanceled.then((_) {
          throw const OperationCanceledException();
        }),
      ]);
    }
    final pgn = chessEverPgnByPlayerId[playerId] ?? '';
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
      replaceExistingSource: true,
    );
  }
}

class _HoldingChessComSnapshotWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _HoldingChessComSnapshotWorkspaceRepository({
    required super.root,
    required super.chessComPgnByUsername,
  });

  final downloadStarted = Completer<void>();
  final _finishDownload = Completer<void>();

  void finishDownload() {
    if (!_finishDownload.isCompleted) _finishDownload.complete();
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    chessComSinceMsRequests.add(sinceMs);
    onProgress?.call('Chess.com: checking source cache...', null);
    if (!downloadStarted.isCompleted) downloadStarted.complete();
    if (cancellationToken == null) {
      await _finishDownload.future;
    } else {
      await Future.any<void>(<Future<void>>[
        _finishDownload.future,
        cancellationToken.whenCanceled.then((_) {
          throw const OperationCanceledException();
        }),
      ]);
    }
    final pgn = chessComPgnByUsername[username.trim().toLowerCase()] ?? '';
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chesscom,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
      replaceExistingSource: true,
    );
  }
}

class _HoldingImportChessEverWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _HoldingImportChessEverWorkspaceRepository({
    required super.root,
    required super.chessEverPgnByPlayerId,
  });

  final importStarted = Completer<void>();
  final _finishImport = Completer<void>();

  void finishImport() {
    if (!_finishImport.isCompleted) _finishImport.complete();
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessEverGames({
    required GamebaseRepository repository,
    required String playerId,
    String? fideId,
    DateTime? sinceDate,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    chessEverSinceDateRequests.add(sinceDate);
    onProgress?.call('Preparing ChessEver games: 1 of 1 ready...', 1);
    final pgn = chessEverPgnByPlayerId[playerId] ?? '';
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
      replaceExistingSource: true,
    );
  }

  @override
  Future<PlayerWorkspaceImportResult> mergeIntoLocalDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String path,
    required String sourceLabel,
    required String pgn,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    if (!importStarted.isCompleted) importStarted.complete();
    if (cancellationToken == null) {
      await _finishImport.future;
    } else {
      await Future.any<void>(<Future<void>>[
        _finishImport.future,
        cancellationToken.whenCanceled.then((_) {
          throw const OperationCanceledException();
        }),
      ]);
    }
    return super.mergeIntoLocalDatabase(
      localRepository: localRepository,
      path: path,
      sourceLabel: sourceLabel,
      pgn: pgn,
      playerAliases: playerAliases,
      playerFideId: playerFideId,
      replaceExisting: replaceExisting,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
  }
}

class _StaleProgressChessEverWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _StaleProgressChessEverWorkspaceRepository({
    required super.root,
    required super.chessEverPgnByPlayerId,
  });

  final firstDownloadStarted = Completer<void>();
  final staleProgressSent = Completer<void>();
  final secondDownloadStarted = Completer<void>();
  final _finishCanceledDownload = Completer<void>();
  final _finishRetryDownload = Completer<void>();
  var _downloadCalls = 0;

  void finishCanceledDownload() {
    if (!_finishCanceledDownload.isCompleted) {
      _finishCanceledDownload.complete();
    }
  }

  void finishRetryDownload() {
    if (!_finishRetryDownload.isCompleted) {
      _finishRetryDownload.complete();
    }
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessEverGames({
    required GamebaseRepository repository,
    required String playerId,
    String? fideId,
    DateTime? sinceDate,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    _downloadCalls += 1;
    chessEverSinceDateRequests.add(sinceDate);
    final pgn = chessEverPgnByPlayerId[playerId] ?? '';
    if (_downloadCalls == 1) {
      onProgress?.call('ChessEver: downloading PGN export...', 0.02);
      if (!firstDownloadStarted.isCompleted) firstDownloadStarted.complete();
      await cancellationToken?.whenCanceled;
      onProgress?.call('ChessEver: stale canceled progress...', 1);
      if (!staleProgressSent.isCompleted) staleProgressSent.complete();
      await _finishCanceledDownload.future;
      throw const OperationCanceledException();
    }

    onProgress?.call('ChessEver: retry download in progress...', 0.25);
    if (!secondDownloadStarted.isCompleted) secondDownloadStarted.complete();
    await _finishRetryDownload.future;
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
    );
  }
}

class _SequencedChessEverWorkspaceRepository
    extends _FakePlayerWorkspaceRepository {
  _SequencedChessEverWorkspaceRepository({
    required super.root,
    required super.chessEverPgnByPlayerId,
    required this.progress,
  });

  final List<({String message, double? progress})> progress;
  final downloadStarted = Completer<void>();
  final _finishDownload = Completer<void>();

  void finishDownload() {
    if (!_finishDownload.isCompleted) _finishDownload.complete();
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessEverGames({
    required GamebaseRepository repository,
    required String playerId,
    String? fideId,
    DateTime? sinceDate,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    chessEverSinceDateRequests.add(sinceDate);
    for (final update in progress) {
      onProgress?.call(update.message, update.progress);
    }
    if (!downloadStarted.isCompleted) downloadStarted.complete();
    if (cancellationToken == null) {
      await _finishDownload.future;
    } else {
      await Future.any<void>(<Future<void>>[
        _finishDownload.future,
        cancellationToken.whenCanceled.then((_) {
          throw const OperationCanceledException();
        }),
      ]);
    }
    final pgn = chessEverPgnByPlayerId[playerId] ?? '';
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
      replaceExistingSource: true,
    );
  }
}

class _FakeGamebaseRepository extends GamebaseRepository {
  _FakeGamebaseRepository(
    this.pgnById, {
    this.pgnExport,
    this.playerGamesError,
    this.externalErrors = const <Object>[],
    this.externalExports =
        const <GamebaseExternalPlayerSource, GamebasePlayerPgnExport>{},
    this.playersById = const <String, GamebasePlayer>{},
  }) : super(Dio());

  final Map<String, String> pgnById;
  final String? pgnExport;
  final Object? playerGamesError;
  final List<Object> externalErrors;
  final Map<GamebaseExternalPlayerSource, GamebasePlayerPgnExport>
  externalExports;
  final Map<String, GamebasePlayer> playersById;
  final exportPlayerIds = <String>[];
  final exportFideIds = <String?>[];
  final exportDateFrom = <String?>[];
  final externalSinceMs = <int?>[];
  final externalReceiveTimeouts = <Duration?>[];
  final requestedProfileIds = <String>[];
  final requestedPlayerIds = <String>[];
  final requestedIncludeData = <bool>[];
  final requestedPageSizes = <int>[];
  final requestedDateFrom = <String?>[];
  final hydratedIds = <String>[];
  var externalRequestCount = 0;

  @override
  Future<GamebasePlayer?> getPlayerById(String id) async {
    requestedProfileIds.add(id);
    return playersById[id];
  }

  @override
  Future<GamebasePlayerPgnExport?> getPlayerGamesPgn({
    required String playerId,
    String? fideId,
    String? dateFrom,
  }) async {
    exportPlayerIds.add(playerId);
    exportFideIds.add(fideId);
    exportDateFrom.add(dateFrom);
    final export = pgnExport;
    if (export == null) return null;
    return GamebasePlayerPgnExport(
      pgn: export,
      gameCount: splitPgnGames(export).length,
    );
  }

  @override
  Future<GamebasePlayerPgnExport?> getExternalPlayerGamesPgn({
    required GamebaseExternalPlayerSource source,
    required String username,
    bool refresh = false,
    int? sinceMs,
    Duration? receiveTimeout,
  }) async {
    externalSinceMs.add(sinceMs);
    externalReceiveTimeouts.add(receiveTimeout);
    final requestIndex = externalRequestCount;
    externalRequestCount += 1;
    if (requestIndex < externalErrors.length) {
      throw externalErrors[requestIndex];
    }
    return externalExports[source];
  }

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
    final error = playerGamesError;
    if (error != null) throw error;
    final pageIds =
        pageNumber == 0
            ? pgnById.keys.toList(growable: false)
            : const <String>[];
    return <String, dynamic>{
      'data': <Map<String, dynamic>>[
        for (final id in pageIds) <String, dynamic>{'id': id},
      ],
      'metadata': <String, dynamic>{'hasMore': false},
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

class _CapturedLocalLibraryRegistry {
  final registered = <String, LocalLibraryEntryMetadata>{};
  final unregistered = <String>[];
  final playerWorkspacesUnregistered = <String>[];

  Future<void> registerAll(
    List<String> paths, {
    required Map<String, LocalLibraryEntryMetadata> metadataByPath,
  }) async {
    for (final path in paths) {
      final metadata = metadataByPath[path];
      if (metadata != null) registered[path] = metadata;
    }
  }

  Future<void> unregister(String path) async {
    registered.remove(path);
    unregistered.add(path);
  }

  Future<void> unregisterPlayerWorkspace(
    String playerId, {
    required Iterable<String> paths,
  }) async {
    playerWorkspacesUnregistered.add(playerId);
    final groupId = '$playerWorkspaceLocalLibraryGroupPrefix${playerId.trim()}';
    final pathSet = paths.map((path) => path.trim()).toSet();
    registered.removeWhere(
      (path, metadata) => metadata.groupId == groupId || pathSet.contains(path),
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
