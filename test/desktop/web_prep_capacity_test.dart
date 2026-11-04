import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/web_prep_access.dart';
import 'package:chessever/desktop/models/player_download_preferences.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/player_workspace_pane.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';

import 'support/desktop_premium_test_overrides.dart';

PlayerWorkspaceAccount _account(int index) => PlayerWorkspaceAccount(
  source: PlayerWorkspaceSource.lichess,
  username: 'account-$index',
);

PlayerWorkspacePlayer _player(String id, {int accounts = 0}) {
  var player = PlayerWorkspacePlayer(id: id, displayName: id, createdAtMs: 1);
  for (var i = 0; i < accounts; i++) {
    player = player.withAccount(_account(i));
  }
  return player;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'own capacity includes extra accounts and excludes computed combined',
    () {
      final own = _player('mine', accounts: 3);
      final withCombined = own.copyWith(
        accounts: {
          ...own.accounts,
          PlayerWorkspaceSource.combined: const PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.combined,
            username: 'Combined',
          ),
        },
      );
      expect(webPrepAccountCount(withCombined), 3);
      expect(
        webPrepCapacityExceeded(
          players: [],
          candidate: withCombined,
          ownPlayerId: 'mine',
        ),
        isNull,
      );
      expect(
        webPrepCapacityExceeded(
          players: [own],
          candidate: own.withAccount(_account(3)),
          ownPlayerId: 'mine',
        ),
        DesktopAccessReason.quotaPrepOwnAccounts,
      );
    },
  );

  test('an over-limit retained profile may refresh or remove accounts', () {
    final own = _player('mine', accounts: 5);
    for (final candidate in [
      own.withAccount(_account(0).copyWith(gameCount: 20)),
      own.withoutAccountEntry(_account(4)),
    ]) {
      expect(
        webPrepCapacityExceeded(
          players: [own],
          candidate: candidate,
          ownPlayerId: 'mine',
        ),
        isNull,
      );
    }
    expect(
      webPrepCapacityExceeded(
        players: [own],
        candidate: own.withAccount(_account(5)),
        ownPlayerId: 'mine',
      ),
      DesktopAccessReason.quotaPrepOwnAccounts,
    );
  });

  test('one opponent is free and the own profile uses no opponent slot', () {
    final own = _player('mine', accounts: 3);
    final opponent = _player('opponent', accounts: 4);
    expect(
      webPrepCapacityExceeded(
        players: [own],
        candidate: opponent,
        ownPlayerId: 'mine',
      ),
      isNull,
    );
    expect(
      webPrepCapacityExceeded(
        players: [own, opponent],
        candidate: _player('second'),
        ownPlayerId: 'mine',
      ),
      DesktopAccessReason.quotaPrepOpponents,
    );
    expect(
      webPrepCapacityExceeded(
        players: [own, opponent],
        candidate: opponent.copyWith(displayName: 'Renamed'),
        ownPlayerId: 'mine',
      ),
      isNull,
    );
  });

  test('controller rejects a second opponent before persisting it', () async {
    final h = await _Harness.create(players: [_player('opponent')]);
    addTearDown(h.dispose);

    await expectLater(
      h.notifier.addManualPlayer('Second opponent'),
      throwsA(isA<DesktopPremiumRequiredException>()),
    );

    expect(h.notifier.state.players.map((p) => p.id), ['opponent']);
    expect(h.repository.writes, 0);
    expect(h.denials, [DesktopAccessReason.quotaPrepOpponents]);
  });

  test(
    'adding a fourth own account leaves the original three unchanged',
    () async {
      final h = await _Harness.create(
        players: [_player('mine', accounts: 2)],
        ownPlayerId: 'mine',
      );
      addTearDown(h.dispose);

      expect(await h.notifier.attachFetchedAccounts([_account(2)]), 1);
      expect(webPrepAccountCount(h.notifier.state.selectedPlayer!), 3);
      final writes = h.repository.writes;
      await expectLater(
        h.notifier.attachFetchedAccounts([_account(3), _account(4)]),
        throwsA(isA<DesktopPremiumRequiredException>()),
      );

      expect(webPrepAccountCount(h.notifier.state.selectedPlayer!), 3);
      expect(h.repository.writes, writes);
      expect(h.denials, [DesktopAccessReason.quotaPrepOwnAccounts]);
    },
  );

  test(
    'an oversized initial own-account batch leaves no orphan profile',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);

      await expectLater(
        h.notifier.addOwnProfileWithAccounts(
          'Mine',
          List.generate(4, _account),
        ),
        throwsA(isA<DesktopPremiumRequiredException>()),
      );

      expect(h.notifier.state.players, isEmpty);
      expect(h.notifier.state.selectedPlayerId, isNull);
      expect(h.repository.writes, 0);
      expect(h.denials, [DesktopAccessReason.quotaPrepOwnAccounts]);
    },
  );

  test(
    'own creation admits three distinct accounts and ignores duplicates',
    () async {
      final h = await _Harness.create(players: [_player('opponent')]);
      addTearDown(h.dispose);

      final id = await h.notifier.addOwnProfileWithAccounts('Mine', [
        _account(0),
        _account(1),
        _account(0),
        _account(2),
      ]);

      expect(h.notifier.state.players, hasLength(2));
      expect(h.notifier.state.selectedPlayerId, id);
      expect(webPrepAccountCount(h.notifier.state.selectedPlayer!), 3);
      expect(h.repository.writes, 1);
      expect(h.denials, isEmpty);
    },
  );

  test('PGN denial precedes manual file reads and workspace writes', () async {
    var prompts = 0;
    final h = await _Harness.create(
      players: [_player('mine')],
      ownPlayerId: 'mine',
      pgnImportGuard: () async {
        prompts++;
        return false;
      },
    );
    addTearDown(h.dispose);

    await expectLater(
      h.notifier.importManualPgnPaths(paths: ['/not-read.pgn']),
      throwsA(isA<DesktopPremiumRequiredException>()),
    );
    await expectLater(
      h.notifier.importManualPgn(label: 'Paste', pgn: '1. e4 e5 *'),
      throwsA(isA<DesktopPremiumRequiredException>()),
    );

    expect(prompts, 2);
    expect(h.repository.manualReads, 0);
    expect(h.repository.writes, 0);
    expect(h.notifier.state.selectedPlayer!.allAccounts, isEmpty);
    expect(h.notifier.state.operations, isEmpty);
  });

  test('disposing while the PGN gate is open prevents further work', () async {
    final gate = Completer<bool>();
    final h = await _Harness.create(
      players: [_player('mine')],
      pgnImportGuard: () => gate.future,
    );
    final pending = h.notifier.importManualPgnPaths(paths: ['/not-read.pgn']);
    h.dispose();
    gate.complete(true);
    await pending;

    expect(h.repository.manualReads, 0);
    expect(h.repository.writes, 0);
  });

  for (final viewportWidth in [1200.0, 640.0]) {
    testWidgets(
      'canceling manual PGN admission keeps dialog text at $viewportWidth px',
      // Match other Forui dialog tests: framework semantics merging is outside
      // this pointer, layout and canceled-admission regression.
      semanticsEnabled: false,
      (tester) async {
        var importPrompts = 0;
        final h = await _Harness.create(
          players: [_player('mine')],
          ownPlayerId: 'mine',
          pgnImportGuard: () async {
            importPrompts++;
            return false;
          },
        );
        await tester.binding.setSurfaceSize(Size(viewportWidth, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...desktopPremiumTestOverrides,
              playerWorkspaceProvider.overrideWith((_) => h.notifier),
              playerWorkspaceRepositoryProvider.overrideWithValue(h.repository),
            ],
            child: const MaterialApp(
              // The underlying desktop pane keeps its normal width; the
              // actual dialog route must fit the narrower browser viewport.
              home: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 1200,
                  height: 800,
                  child: PlayerWorkspacePane(pinnedPlayerId: 'mine'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Import PGN').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import PGN').first);
        await tester.pumpAndSettle();
        final writesBeforeImport = h.repository.writes;
        const pgn = '[White "Mine"]\n[Result "*"]\n\n1. e4 e5 *';
        await tester.enterText(find.byType(TextField).last, pgn);
        await tester.pump();
        await tester.tap(find.text('Import pasted PGN'));
        await tester.pumpAndSettle();

        expect(find.text('Import manual PGN'), findsOneWidget);
        expect(find.text(pgn), findsOneWidget);
        expect(importPrompts, 1);
        expect(h.repository.writes, writesBeforeImport);
        expect(h.repository.manualReads, 0);
        expect(h.notifier.state.selectedPlayer!.allAccounts, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
        expect(find.text('Import manual PGN'), findsNothing);
        expect(h.repository.writes, writesBeforeImport);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'free own account can request its first download without PGN gate',
    () async {
      var pgnPrompts = 0;
      final h = await _Harness.create(
        players: [_player('mine', accounts: 1)],
        ownPlayerId: 'mine',
        pgnImportGuard: () async {
          pgnPrompts++;
          return false;
        },
      );
      addTearDown(h.dispose);

      await expectLater(
        h.notifier.syncAccount(_account(0)),
        throwsA(isA<_DownloadRequested>()),
      );

      expect(h.repository.downloads, 1);
      expect(pgnPrompts, 0);
      expect(h.denials, isEmpty);
      expect(webPrepAccountCount(h.notifier.state.selectedPlayer!), 1);
      expect(h.notifier.state.operations, isEmpty);
    },
  );
}

class _Harness {
  _Harness(this.repository, this.notifier, this.denials);

  final _WorkspaceRepository repository;
  final PlayerWorkspaceNotifier notifier;
  final List<DesktopAccessReason> denials;

  static Future<_Harness> create({
    List<PlayerWorkspacePlayer> players = const [],
    String? ownPlayerId,
    Future<bool> Function()? pgnImportGuard,
  }) async {
    final repository = _WorkspaceRepository(
      PlayerWorkspaceSnapshot(
        players: players,
        selectedPlayerId: players.firstOrNull?.id,
      ),
    );
    final denials = <DesktopAccessReason>[];
    late final PlayerWorkspaceNotifier notifier;
    notifier = PlayerWorkspaceNotifier(
      workspaceRepository: repository,
      gamebaseRepository: GamebaseRepository(Dio()),
      localRepository: LocalChessDatabaseRepository(
        database: () => throw StateError('No local database work expected'),
      ),
      accessGuard:
          (action, {required interactive}) => action != DesktopAction.recompute,
      capacityGuard: (candidate, {required ownProfile}) {
        final reason = webPrepCapacityExceeded(
          players: notifier.state.players,
          candidate: candidate,
          ownPlayerId: ownProfile ? candidate.id : ownPlayerId,
        );
        if (reason != null) denials.add(reason);
        return reason == null;
      },
      pgnImportGuard: pgnImportGuard,
    );
    await notifier.load();
    return _Harness(repository, notifier, denials);
  }

  void dispose() => notifier.dispose();
}

class _DownloadRequested implements Exception {}

class _WorkspaceRepository extends PlayerWorkspaceRepository {
  _WorkspaceRepository(this.snapshot);

  PlayerWorkspaceSnapshot snapshot;
  int writes = 0;
  int manualReads = 0;
  int downloads = 0;

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
    writes++;
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> readManualPgnPaths({
    required List<String> paths,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    manualReads++;
    throw StateError('Denied PGN import must not read files');
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    PlayerDownloadPreferences preferences = const PlayerDownloadPreferences(),
    bool forceRefresh = false,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    downloads++;
    throw _DownloadRequested();
  }
}
