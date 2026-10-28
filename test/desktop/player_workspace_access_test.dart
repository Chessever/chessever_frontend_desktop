import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/gamebase/models/models.dart';

const _pgn = '''[Event "A"]
[White "spy-user"]
[Black "Other"]
[Result "1-0"]

1. e4 e5 1-0

[Event "B"]
[White "Other"]
[Black "spy-user"]
[Result "1/2-1/2"]

1. d4 d5 1/2-1/2
''';

void main() {
  late Directory temp;
  late resqlite.Database db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever-prepare-access-');
    db = await resqlite.Database.open(p.join(temp.path, 'local_chess.db'));
    await createLocalChessResqliteDatabaseSchema(db);
    desktopWindowIsForeground = () => true;
  });

  tearDown(() async {
    await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// A retained prep target with a downloaded PGN whose stored stats are
  /// stale (0 games), and a combined database on disk.
  Future<PlayerWorkspacePlayer> retainedPlayer() async {
    final dir = Directory(p.join(temp.path, 'player-workspace', 'spy'));
    await dir.create(recursive: true);
    final pgnPath = p.join(dir.path, 'chesscom.pgn');
    await File(pgnPath).writeAsString(_pgn);
    final combinedPath = p.join(dir.path, 'combined.pgn');
    await File(combinedPath).writeAsString(_pgn);
    return PlayerWorkspacePlayer(
      id: 'spy',
      displayName: 'Spy Target',
      createdAtMs: 1,
      combinedPgnPath: combinedPath,
      accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
        PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
          source: PlayerWorkspaceSource.chesscom,
          username: 'spy-user',
          pgnPath: pgnPath,
        ),
      },
    );
  }

  Future<_Harness> harness({required bool premium}) async {
    final player = await retainedPlayer();
    final container = ProviderContainer(
      overrides: [
        subscriptionProvider.overrideWith(
          (ref) => SubscriptionNotifier.stub(
            premium
                ? SubscriptionState(
                  isSubscribed: true,
                  expirationDate: DateTime.now().add(const Duration(days: 30)),
                )
                : SubscriptionState(),
          ),
        ),
        desktopEntitlementProvider.overrideWithValue(
          const DesktopEntitlementSnapshot(accountId: 'acct', generation: 1),
        ),
      ],
    );
    final presented = <String>[];
    final unregister = registerDesktopPaywallPresenter(container, (
      decision, {
      DesktopAccessContext? context,
      DesktopAccessResume? resume,
      required String surface,
    }) async {
      presented.add(decision.reason.code);
      return false;
    });
    final guardLog = <String>[];
    final repository = _SpyWorkspaceRepository(
      root: temp,
      snapshot: PlayerWorkspaceSnapshot(
        players: <PlayerWorkspacePlayer>[player],
        selectedPlayerId: player.id,
      ),
      combinedCurrent: true,
    );
    final local = _SpyLocalRepository(db);
    final notifier = PlayerWorkspaceNotifier(
      // The production wiring, against a real container.
      accessGuard: (action, {required interactive}) {
        final allowed = admitDesktopAction(
          container,
          DesktopAccessContext(
            feature: DesktopFeature.prepare,
            action: action,
            origin: DesktopDiscoveryOrigin.localFile,
          ),
          surface: 'test_prepare',
          interactive: interactive,
        );
        guardLog.add('${action.name}:$interactive:$allowed');
        return allowed;
      },
      workspaceRepository: repository,
      gamebaseRepository: GamebaseRepository(Dio()),
      localRepository: local,
    );
    return _Harness(
      container: container,
      unregister: unregister,
      notifier: notifier,
      repository: repository,
      local: local,
      presented: presented,
      guardLog: guardLog,
      player: player,
    );
  }

  test(
    'a free user load runs no stats repair and no combined rebuild',
    () async {
      final h = await harness(premium: false);
      addTearDown(h.dispose);
      await h.notifier.load();

      expect(h.local.resultStatsCalls, 0, reason: 'combined stats repair');
      expect(
        h.repository.combinedCurrentChecks,
        0,
        reason: 'stale combined rebuild never starts',
      );
      final account = h.notifier.state.players.single.account(
        PlayerWorkspaceSource.chesscom,
      )!;
      expect(account.gameCount, 0, reason: 'account stats left as stored');
      expect(h.presented, isEmpty, reason: 'load never opens a paywall');
      expect(h.guardLog, everyElement(startsWith('recompute:false:')));

      // Selecting retained work is browsing: still no recompute, no paywall.
      await h.notifier.selectPlayer(h.player.id);
      expect(h.repository.combinedCurrentChecks, 0);
      expect(h.presented, isEmpty);
    },
  );

  test('control: a member load does repair and check the combined DB', () async {
    final h = await harness(premium: true);
    addTearDown(h.dispose);
    await h.notifier.load();

    expect(h.local.resultStatsCalls, greaterThan(0));
    expect(h.repository.combinedCurrentChecks, greaterThan(0));
    expect(h.presented, isEmpty);
  });

  test('rename, remove and export stay allowed for a free user', () async {
    final h = await harness(premium: false);
    addTearDown(h.dispose);
    await h.notifier.load();
    h.guardLog.clear();

    await h.notifier.renamePlayer(h.player.id, 'Renamed Target');
    expect(h.notifier.state.players.single.displayName, 'Renamed Target');

    await h.notifier.removePlayer(h.player.id);
    expect(h.notifier.state.players, isEmpty);
    await h.notifier.debugDrainPlayerCleanup();

    // Export of retained prep files has no Premium gate anywhere.
    expect(
      admitDesktopAction(
        h.container,
        const DesktopAccessContext(
          feature: DesktopFeature.prepare,
          action: DesktopAction.export,
          origin: DesktopDiscoveryOrigin.localFile,
        ),
        surface: 'test_export',
      ),
      isTrue,
    );

    expect(
      h.guardLog.where((entry) => entry.endsWith(':false')),
      isEmpty,
      reason: 'no free-user data action was denied',
    );
    expect(h.presented, isEmpty);
  });

  test('a free add presents once; search fails typed and runs no query', () async {
    final h = await harness(premium: false);
    addTearDown(h.dispose);
    await h.notifier.load();

    await expectLater(
      h.notifier.addManualPlayer('New Target'),
      throwsA(isA<DesktopPremiumRequiredException>()),
    );
    expect(h.presented, <String>['premium_prepare_target']);
    expect(h.notifier.state.players, hasLength(1));

    await expectLater(
      h.notifier.searchChessEverPlayers('carlsen'),
      throwsA(isA<DesktopPremiumRequiredException>()),
    );
    expect(h.repository.searchCalls, 0);
    expect(h.presented, hasLength(1), reason: 'search never presents');
  });
}

class _Harness {
  _Harness({
    required this.container,
    required this.unregister,
    required this.notifier,
    required this.repository,
    required this.local,
    required this.presented,
    required this.guardLog,
    required this.player,
  });

  final ProviderContainer container;
  final void Function() unregister;
  final PlayerWorkspaceNotifier notifier;
  final _SpyWorkspaceRepository repository;
  final _SpyLocalRepository local;
  final List<String> presented;
  final List<String> guardLog;
  final PlayerWorkspacePlayer player;

  Future<void> dispose() async {
    await notifier.debugDrainPlayerCleanup();
    notifier.dispose();
    unregister();
    container.dispose();
  }
}

class _SpyWorkspaceRepository extends PlayerWorkspaceRepository {
  _SpyWorkspaceRepository({
    required this.root,
    required this.snapshot,
    required this.combinedCurrent,
  }) : super(supportDirectory: () async => root);

  final Directory root;
  PlayerWorkspaceSnapshot snapshot;
  final bool combinedCurrent;
  int combinedCurrentChecks = 0;
  int searchCalls = 0;

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }

  @override
  Future<bool> isCombinedDatabaseCurrent(String path) async {
    combinedCurrentChecks += 1;
    return combinedCurrent;
  }

  @override
  Future<List<GamebasePlayer>> searchChessEverPlayers(
    GamebaseRepository repository,
    String query,
  ) async {
    searchCalls += 1;
    return const <GamebasePlayer>[];
  }

  @override
  Future<bool> deleteSourcePgnFile(String path) async => false;

  @override
  Future<bool> deletePlayerWorkspaceDirectory(String playerId) async => false;
}

class _SpyLocalRepository extends LocalChessDatabaseRepository {
  _SpyLocalRepository(resqlite.Database db) : super(database: () async => db);

  int resultStatsCalls = 0;

  @override
  Future<LocalChessDatabaseResultStats> localDatabaseResultStats({
    required String databasePath,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool preferDirectDatabase = false,
  }) {
    resultStatsCalls += 1;
    throw StateError('spy: stats repair must not run for a free user');
  }
}
