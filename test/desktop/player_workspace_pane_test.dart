import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/player_workspace_pane.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/library/local_tree_action_button.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('places Combined immediately above Manual PGN in the source rail', () {
    expect(playerWorkspaceSourceRailOrder, <PlayerWorkspaceSource>[
      PlayerWorkspaceSource.chessever,
      PlayerWorkspaceSource.lichess,
      PlayerWorkspaceSource.chesscom,
      PlayerWorkspaceSource.combined,
      PlayerWorkspaceSource.manual,
    ]);
  });

  group('player library row labels', () {
    test('keeps the title chip value out of the white player name', () {
      expect(
        playerWorkspaceDisplayName(
          const PlayerWorkspacePlayer(
            id: 'hikaru',
            displayName: 'GM Hikaru Nakamura',
            createdAtMs: 1,
            title: 'GM',
          ),
        ),
        'Hikaru Nakamura',
      );
      expect(
        playerWorkspaceDisplayName(
          const PlayerWorkspacePlayer(
            id: 'vasif',
            displayName: 'gm Vasif Durarbayli',
            createdAtMs: 1,
            title: 'GM',
          ),
        ),
        'Vasif Durarbayli',
      );
    });

    test('keeps an unprefixed player name unchanged', () {
      expect(
        playerWorkspaceDisplayName(
          const PlayerWorkspacePlayer(
            id: 'judit',
            displayName: 'Judit Polgar',
            createdAtMs: 1,
            title: 'GM',
          ),
        ),
        'Judit Polgar',
      );
    });
  });

  testWidgets('connects a Lichess account without framework exceptions', (
    tester,
  ) async {
    await _expectOnlineAccountConnects(
      tester,
      sourceButtonIndex: 1,
      username: 'DrNykterstein',
    );
  });

  testWidgets('connects a Chess.com account without framework exceptions', (
    tester,
  ) async {
    await _expectOnlineAccountConnects(
      tester,
      sourceButtonIndex: 2,
      username: 'Hikaru',
    );
  });

  testWidgets('shows determinate Lichess download progress while syncing', (
    tester,
  ) async {
    await _expectOnlineDownloadShowsProgress(
      tester,
      sourceButtonIndex: 1,
      username: 'DrNykterstein',
      expectedProgressMessage: 'Receiving Lichess games: 21 of about 42...',
    );
  });

  testWidgets('shows determinate Chess.com download progress while syncing', (
    tester,
  ) async {
    await _expectOnlineDownloadShowsProgress(
      tester,
      sourceButtonIndex: 2,
      username: 'Hikaru',
      expectedProgressMessage:
          'Chess.com: 1/2 archives done; 42 games received...',
    );
  });

  testWidgets('keeps built tree actions when another player source is built', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chessever-player-pane-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final lichessPath = '${temp.path}/lichess.pgn';
    final chessComPath = '${temp.path}/chesscom.pgn';
    File(lichessPath).writeAsStringSync(_paneTestPgn('lichess_user'));
    File(chessComPath).writeAsStringSync(_paneTestPgn('chesscom_user'));

    final repository = _PaneFakePlayerWorkspaceRepository(
      snapshot: PlayerWorkspaceSnapshot(
        players: [
          PlayerWorkspacePlayer(
            id: 'player-1',
            displayName: 'Prep Target',
            createdAtMs: 1,
            accounts: {
              PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.lichess,
                username: 'lichess_user',
                pgnPath: lichessPath,
                gameCount: 2,
              ),
              PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.chesscom,
                username: 'chesscom_user',
                pgnPath: chessComPath,
                gameCount: 3,
              ),
            },
          ),
        ],
      ),
    );
    final localRepository = _PaneMutableTreeLocalChessDatabaseRepository({
      lichessPath: 2,
      chessComPath: 3,
    });
    final registry = LocalLibraryRegistryNotifier(_PaneMemoryAppDatabase());

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
          localChessDatabaseRepositoryProvider.overrideWithValue(
            localRepository,
          ),
          localLibraryRegistryProvider.overrideWith((ref) => registry),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(
              localDatabaseRepository: localRepository,
            ),
          ),
        ],
        child: const MaterialApp(
          home: _ResponsiveTestHost(
            child: SizedBox(
              width: 1200,
              height: 800,
              child: PlayerWorkspacePane(),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.widgetWithText(DesktopHeaderActionButton, 'Add player'),
      findsOneWidget,
    );
    await tester.tap(find.text('Prep Target').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.widgetWithText(DesktopHeaderActionButton, 'All players'),
      findsNothing,
    );
    expect(
      find.widgetWithText(DesktopHeaderActionButton, 'Add player'),
      findsNothing,
    );
    await tester.tap(find.text('Build Tree').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.text('Opening trees'), findsOneWidget);
    expect(
      find.widgetWithText(LocalTreeActionButton, 'Build Tree'),
      findsNWidgets(2),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerWorkspacePane)),
    );

    await tester.tap(
      find.widgetWithText(LocalTreeActionButton, 'Build Tree').first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(localRepository.indexes.keys, hasLength(1));
    final firstBuiltPath = localRepository.indexes.keys.single;
    expect(firstBuiltPath, isIn([lichessPath, chessComPath]));
    expect(find.widgetWithText(LocalTreeActionButton, 'Tree'), findsOneWidget);
    final firstBoardTabs = container
        .read(desktopTabsProvider)
        .tabs
        .where((tab) => tab.kind == TabKind.board)
        .toList(growable: false);
    expect(firstBoardTabs, hasLength(1));
    expect(
      container.read(desktopTabsProvider).activeId,
      firstBoardTabs.single.id,
    );
    final openedTree =
        container
            .read(boardTabGameArgsByTabIdProvider)[firstBoardTabs.single.id]
            ?.localOpeningTreeIndex;
    expect(openedTree?.playerId, firstBuiltPath);
    expect(
      container.read(rightRailActivePageProvider(firstBoardTabs.single.id)),
      1,
    );

    await tester.tap(
      find.widgetWithText(LocalTreeActionButton, 'Build Tree').first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(
      localRepository.indexes.keys,
      containsAll([lichessPath, chessComPath]),
    );
    expect(
      find.widgetWithText(LocalTreeActionButton, 'Tree'),
      findsNWidgets(2),
    );
    expect(
      find.widgetWithText(LocalTreeActionButton, 'Build Tree'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('builds and opens the selected Games source tree', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'chessever-player-games-tree-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final lichessPath = '${temp.path}/lichess.pgn';
    File(lichessPath).writeAsStringSync(_paneTestPgn('lichess_user'));
    final repository = _PaneFakePlayerWorkspaceRepository(
      snapshot: PlayerWorkspaceSnapshot(
        players: [
          PlayerWorkspacePlayer(
            id: 'player-1',
            displayName: 'Prep Target',
            createdAtMs: 1,
            accounts: {
              PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.lichess,
                username: 'lichess_user',
                pgnPath: lichessPath,
                gameCount: 2,
              ),
            },
          ),
        ],
      ),
    );
    final localRepository = _PaneMutableTreeLocalChessDatabaseRepository({
      lichessPath: 2,
    });
    final registry = LocalLibraryRegistryNotifier(_PaneMemoryAppDatabase());

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
          localChessDatabaseRepositoryProvider.overrideWithValue(
            localRepository,
          ),
          localLibraryRegistryProvider.overrideWith((ref) => registry),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(
              localDatabaseRepository: localRepository,
            ),
          ),
        ],
        child: const MaterialApp(
          home: _ResponsiveTestHost(
            child: SizedBox(
              width: 1200,
              height: 800,
              child: PlayerWorkspacePane(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Prep Target').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Games').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(LocalTreeActionButton, 'Build Tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(localRepository.indexes.keys, contains(lichessPath));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerWorkspacePane)),
    );
    final boardTabs = container
        .read(desktopTabsProvider)
        .tabs
        .where((tab) => tab.kind == TabKind.board)
        .toList(growable: false);
    expect(boardTabs, hasLength(1));
    expect(container.read(desktopTabsProvider).activeId, boardTabs.single.id);
    expect(
      container
          .read(boardTabGameArgsByTabIdProvider)[boardTabs.single.id]
          ?.localOpeningTreeIndex
          ?.playerId,
      lichessPath,
    );
    expect(container.read(rightRailActivePageProvider(boardTabs.single.id)), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows persisted tree actions for multiple player sources', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chessever-player-pane-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final lichessPath = '${temp.path}/lichess.pgn';
    final chessComPath = '${temp.path}/chesscom.pgn';
    final combinedPath = '${temp.path}/combined.pgn';
    File(lichessPath).writeAsStringSync(_paneTestPgn('lichess_user'));
    File(chessComPath).writeAsStringSync(_paneTestPgn('chesscom_user'));
    File(combinedPath).writeAsStringSync(_paneTestPgn('combined_user'));

    final repository = _PaneFakePlayerWorkspaceRepository(
      snapshot: PlayerWorkspaceSnapshot(
        players: [
          PlayerWorkspacePlayer(
            id: 'player-1',
            displayName: 'Prep Target',
            createdAtMs: 1,
            accounts: {
              PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.lichess,
                username: 'lichess_user',
                pgnPath: lichessPath,
                gameCount: 2,
              ),
              PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.chesscom,
                username: 'chesscom_user',
                pgnPath: chessComPath,
                gameCount: 3,
              ),
            },
            combinedPgnPath: combinedPath,
            combinedGameCount: 5,
          ),
        ],
      ),
    );
    final localRepository = _PaneFakeLocalChessDatabaseRepository({
      lichessPath: _paneTreeIndex(path: lichessPath, gameCount: 2),
      chessComPath: _paneTreeIndex(path: chessComPath, gameCount: 3),
      combinedPath: _paneTreeIndex(path: combinedPath, gameCount: 5),
    });

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
          localChessDatabaseRepositoryProvider.overrideWithValue(
            localRepository,
          ),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(
              localDatabaseRepository: localRepository,
            ),
          ),
        ],
        child: const MaterialApp(
          home: _ResponsiveTestHost(
            child: SizedBox(
              width: 1200,
              height: 800,
              child: PlayerWorkspacePane(),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.tap(find.text('Prep Target').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Build Tree').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(find.text('Opening trees'), findsOneWidget);
    expect(find.text('Tree'), findsNWidgets(3));
    expect(find.text('Prep Target Combined'), findsOneWidget);
    expect(find.text('5 games · Both colours'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FIDE-locked ChessEver reconnect skips player search', (
    tester,
  ) async {
    final repository = _PaneFakePlayerWorkspaceRepository(
      snapshot: const PlayerWorkspaceSnapshot(
        players: [
          PlayerWorkspacePlayer(
            id: 'player-1',
            displayName: 'GM Vasif Durarbayli',
            createdAtMs: 1,
            fideId: '13402935',
            title: 'GM',
            country: 'AZE',
          ),
        ],
      ),
      chessEverSearchResults: const [
        GamebasePlayer(
          id: 'ce-carlsen',
          fideId: '1503014',
          name: 'Carlsen, Magnus',
          gender: PlayerGender.male,
          fed: 'NOR',
          title: 'GM',
        ),
        GamebasePlayer(
          id: 'ce-vasif',
          fideId: '13402935',
          name: 'Durarbayli, Vasif',
          gender: PlayerGender.male,
          fed: 'AZE',
          title: 'GM',
        ),
      ],
    );

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 800,
            child: PlayerWorkspacePane(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Vasif Durarbayli').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account').first);
    await tester.pumpAndSettle();
    if (find
        .text('Choose the source to connect to this player.')
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.text('ChessEver').last);
    }
    await repository.onlineImportFinished.future.timeout(
      const Duration(seconds: 5),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connect ChessEver'), findsNothing);
    expect(find.textContaining('Locked to FIDE 13402935'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(repository.fideLookupRequests, <String>['13402935']);
    expect(
      repository.snapshot.players.single
          .account(PlayerWorkspaceSource.chessever)
          ?.gameCount,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no-FIDE ChessEver connection keeps the search dialog', (
    tester,
  ) async {
    final repository = _PaneFakePlayerWorkspaceRepository();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 800,
            child: PlayerWorkspacePane(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Prep Target').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account').first);
    await tester.pumpAndSettle();
    if (find
        .text('Choose the source to connect to this player.')
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.text('ChessEver').last);
      await tester.pumpAndSettle();
    }

    expect(find.text('Connect ChessEver'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(repository.fideLookupRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initial Add Player always exposes manual creation', (
    tester,
  ) async {
    final repository = _PaneFakePlayerWorkspaceRepository();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 800,
            child: PlayerWorkspacePane(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Add player').first);
    await tester.pumpAndSettle();

    expect(find.text('Create manual player'), findsOneWidget);
    expect(find.text('Add & connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding the same FIDE player reopens its existing workspace', (
    tester,
  ) async {
    const existingPlayerId = 'existing-fide-player';
    const reindexedPlayer = GamebasePlayer(
      id: 'ce-after-reindex',
      fideId: '1503014',
      name: 'Carlsen, Magnus',
      gender: PlayerGender.male,
      fed: 'NOR',
      title: 'GM',
    );
    final repository = _PaneFakePlayerWorkspaceRepository(
      snapshot: const PlayerWorkspaceSnapshot(
        players: [
          PlayerWorkspacePlayer(
            id: existingPlayerId,
            displayName: 'GM Magnus Carlsen',
            createdAtMs: 1,
            fideId: '1503014',
            chesseverPlayerId: 'ce-before-reindex',
            accounts: {
              PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.chessever,
                username: 'Magnus Carlsen',
                externalId: 'ce-before-reindex',
              ),
            },
          ),
        ],
      ),
      chessEverSearchResults: const [reindexedPlayer],
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 800,
            child: PlayerWorkspacePane(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Add player').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Magnus');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GM Magnus Carlsen').last);
    await tester.pumpAndSettle();

    expect(repository.snapshot.players, hasLength(1));
    expect(repository.snapshot.selectedPlayerId, existingPlayerId);
    expect(
      repository.snapshot.players.single.chesseverPlayerId,
      'ce-before-reindex',
    );
    expect(find.text('Accounts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account ownership error identifies the existing player', (
    tester,
  ) async {
    final repository = _PaneFakePlayerWorkspaceRepository(
      snapshot: const PlayerWorkspaceSnapshot(
        players: [
          PlayerWorkspacePlayer(
            id: 'owner',
            displayName: 'GM Existing Owner',
            createdAtMs: 2,
            fideId: '1503014',
            accounts: {
              PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.lichess,
                username: 'SharedHandle',
              ),
            },
          ),
          PlayerWorkspacePlayer(
            id: 'target',
            displayName: 'New Target',
            createdAtMs: 1,
          ),
        ],
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          _playerWorkspaceOverride(repository),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 800,
            child: PlayerWorkspacePane(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('New Target').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account').at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sharedhandle');
    await tester.pump();
    await tester.tap(find.text('Add').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 1 username'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.text(
        'The Lichess account "sharedhandle" is already attached to '
        '"GM Existing Owner" (FIDE 1503014). Open that player workspace '
        'to manage it.',
      ),
      findsOneWidget,
    );
    expect(
      repository.snapshot.players
          .singleWhere((player) => player.id == 'target')
          .allAccounts,
      isEmpty,
    );
    expect(find.textContaining('Bad state:'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _expectOnlineAccountConnects(
  WidgetTester tester, {
  required int sourceButtonIndex,
  required String username,
}) async {
  final repository = _PaneFakePlayerWorkspaceRepository();
  await _pumpAndConnectOnlineAccount(
    tester,
    repository: repository,
    sourceButtonIndex: sourceButtonIndex,
    username: username,
  );

  expect(find.text(username), findsWidgets);
  expect(tester.takeException(), isNull);
}

Future<void> _expectOnlineDownloadShowsProgress(
  WidgetTester tester, {
  required int sourceButtonIndex,
  required String username,
  required String expectedProgressMessage,
}) async {
  final repository =
      _PaneFakePlayerWorkspaceRepository()..holdNextOnlineDownload();
  await _pumpAndConnectOnlineAccount(
    tester,
    repository: repository,
    sourceButtonIndex: sourceButtonIndex,
    username: username,
  );

  await tester.tap(find.text('Download games').first);
  await tester.pump(const Duration(milliseconds: 250));
  await repository.onlineDownloadStarted.future.timeout(
    const Duration(seconds: 5),
  );
  await tester.pump();

  expect(find.text(expectedProgressMessage), findsWidgets);
  expect(find.text('23%'), findsWidgets);
  expect(tester.takeException(), isNull);

  repository.finishOnlineDownload();
  await repository.onlineImportFinished.future.timeout(
    const Duration(seconds: 5),
  );
  await tester.pump(const Duration(milliseconds: 250));
  expect(tester.takeException(), isNull);
}

Future<void> _pumpAndConnectOnlineAccount(
  WidgetTester tester, {
  required _PaneFakePlayerWorkspaceRepository repository,
  required int sourceButtonIndex,
  required String username,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerWorkspaceRepositoryProvider.overrideWithValue(repository),
        _playerWorkspaceOverride(repository),
      ],
      child: const MaterialApp(
        home: SizedBox(width: 1200, height: 800, child: PlayerWorkspacePane()),
      ),
    ),
  );

  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('Prep Target'), findsOneWidget);

  await tester.tap(find.text('Prep Target').first);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);

  await tester.tap(find.text('Add account').at(sourceButtonIndex));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);

  await tester.enterText(find.byType(TextField), username);
  await tester.pump();
  expect(tester.takeException(), isNull);

  await tester.tap(find.text('Add').last);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);

  await tester.tap(find.text('Add 1 username'));
  await tester.pumpAndSettle();
}

Override _playerWorkspaceOverride(
  _PaneFakePlayerWorkspaceRepository repository,
) {
  return playerWorkspaceProvider.overrideWith(
    (ref) => PlayerWorkspaceNotifier(
      workspaceRepository: repository,
      gamebaseRepository: ref.watch(gamebaseRepositoryProvider),
      localRepository: ref.watch(localChessDatabaseRepositoryProvider),
    ),
  );
}

class _ResponsiveTestHost extends StatelessWidget {
  const _ResponsiveTestHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    ResponsiveHelper.init(context);
    return child;
  }
}

class _PaneFakePlayerWorkspaceRepository extends PlayerWorkspaceRepository {
  _PaneFakePlayerWorkspaceRepository({
    PlayerWorkspaceSnapshot? snapshot,
    this.chessEverSearchResults = const <GamebasePlayer>[],
  }) : snapshot =
           snapshot ??
           const PlayerWorkspaceSnapshot(
             players: [
               PlayerWorkspacePlayer(
                 id: 'manual-1',
                 displayName: 'Prep Target',
                 createdAtMs: 1,
               ),
             ],
           );

  PlayerWorkspaceSnapshot snapshot;
  final List<GamebasePlayer> chessEverSearchResults;
  final fideLookupRequests = <String>[];
  Completer<void> onlineDownloadStarted = Completer<void>();
  Completer<void> onlineImportFinished = Completer<void>();
  Completer<void>? _finishOnlineDownload;

  void holdNextOnlineDownload() {
    onlineDownloadStarted = Completer<void>();
    onlineImportFinished = Completer<void>();
    _finishOnlineDownload = Completer<void>();
  }

  void finishOnlineDownload() {
    _finishOnlineDownload?.complete();
    _finishOnlineDownload = null;
  }

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }

  @override
  Future<List<GamebasePlayer>> searchChessEverPlayers(
    GamebaseRepository repository,
    String query,
  ) async {
    return chessEverSearchResults;
  }

  @override
  Future<GamebasePlayer?> findChessEverPlayerByFideId(
    GamebaseRepository repository,
    String fideId,
  ) async {
    fideLookupRequests.add(fideId);
    for (final player in chessEverSearchResults) {
      if (player.fideId.trim() == fideId.trim()) return player;
    }
    return null;
  }

  @override
  Future<PlayerWorkspaceAccount> fetchLichessAccount(String username) async {
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.lichess,
      username: username.trim(),
      displayName: username.trim(),
      availableGameCount: 42,
      ratings: const {'Blitz': 3200},
    );
  }

  @override
  Future<PlayerWorkspaceAccount> fetchChessComAccount(String username) async {
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.chesscom,
      username: username.trim(),
      displayName: username.trim(),
      availableGameCount: 84,
      ratings: const {'Blitz': 3300},
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) {
    expect(expectedGameCount, 42);
    return _downloadOnlineGames(
      source: PlayerWorkspaceSource.lichess,
      message: 'Receiving Lichess games: 21 of about 42...',
      username: username,
      onProgress: onProgress,
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) {
    return _downloadOnlineGames(
      source: PlayerWorkspaceSource.chesscom,
      message: 'Chess.com: 1/2 archives done; 42 games received...',
      username: username,
      onProgress: onProgress,
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
  }) {
    return _downloadOnlineGames(
      source: PlayerWorkspaceSource.chessever,
      message: 'Downloading ChessEver games...',
      username: 'GM Vasif Durarbayli',
      onProgress: onProgress,
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> _downloadOnlineGames({
    required PlayerWorkspaceSource source,
    required String message,
    required String username,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    onProgress?.call(message, 0.5);
    if (!onlineDownloadStarted.isCompleted) {
      onlineDownloadStarted.complete();
    }
    final completer = _finishOnlineDownload;
    if (completer != null) await completer.future;
    return PlayerWorkspaceDownloadedPgn(
      source: source,
      pgn: _paneTestPgn(username),
      gameCount: 1,
    );
  }

  @override
  Future<String> sourcePgnPath({
    required String playerId,
    String? playerName,
    String? fideId,
    required PlayerWorkspaceSource source,
    String? username,
  }) async {
    return '/tmp/${source.storageKey}-${username ?? 'source'}.pgn';
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
    onProgress?.call('Importing $sourceLabel...', 0.75);
    return PlayerWorkspaceImportResult(
      path: path,
      stats: const PlayerWorkspaceImportStats(gameCount: 1, newGameCount: 1),
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
    onProgress?.call('Combining and deduplicating games...', 1);
    if (!onlineImportFinished.isCompleted) {
      onlineImportFinished.complete();
    }
    return const PlayerWorkspaceImportResult(
      path: '/tmp/combined.pgn',
      stats: PlayerWorkspaceImportStats(gameCount: 1),
    );
  }
}

class _PaneFakeLocalChessDatabaseRepository
    extends LocalChessDatabaseRepository {
  _PaneFakeLocalChessDatabaseRepository(this.indexes)
    : super(database: () async => throw StateError('unused test database'));

  final Map<String, PlayerOpeningTreeIndex> indexes;

  @override
  Future<LocalChessFileNode?> loadFreshFileNode(
    String path, {
    required String rootPath,
    LocalChessScanProgressSink? onProgress,
  }) async {
    final index = indexes[path];
    if (index == null) return null;
    return LocalChessFileNode(
      name: path.split('/').last,
      path: path,
      relativePath: path,
      extension: '.pgn',
      status: LocalChessFileStatus.parsed,
      games: const <LocalChessGame>[],
      gameCount: index.downloadedGameCount,
      sizeBytes: 1,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1),
      openingTreeIndex: index,
    );
  }
}

class _PaneMemoryAppDatabase implements AppDatabase {
  final Map<String, Object?> _values = <String, Object?>{};

  @override
  Future<T?> getJson<T>(String key) async => _values[key] as T?;

  @override
  Future<void> setJson(String key, Object value) async {
    _values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PaneMutableTreeLocalChessDatabaseRepository
    extends LocalChessDatabaseRepository {
  _PaneMutableTreeLocalChessDatabaseRepository(this.gameCountsByPath)
    : super(database: () async => throw StateError('unused test database'));

  final Map<String, int> gameCountsByPath;
  final Map<String, PlayerOpeningTreeIndex> indexes = {};

  @override
  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
    LocalChessScanProgressSink? onProgress,
  }) async {
    if (paths.isEmpty) return null;
    final cleanPaths = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (cleanPaths.isEmpty) return null;
    final rootPath =
        cleanPaths.length == 1
            ? File(cleanPaths.single).parent.path
            : Directory.systemTemp.path;
    return LocalChessSource(
      id: 'pane-source:${cleanPaths.join('|')}',
      label: sourceLabel ?? 'Pane source',
      paths: cleanPaths,
      rootPath: rootPath,
      scannedAt: DateTime.fromMillisecondsSinceEpoch(1),
      root: LocalChessFolderNode.fromChildren(
        name: sourceLabel ?? 'Pane source',
        path: rootPath,
        relativePath: '',
        children: [
          for (final path in cleanPaths) _fileNode(path, rootPath: rootPath),
        ],
      ),
    );
  }

  @override
  Future<LocalChessFileNode?> loadFreshFileNode(
    String path, {
    required String rootPath,
    LocalChessScanProgressSink? onProgress,
  }) async {
    final clean = path.trim();
    if (!gameCountsByPath.containsKey(clean)) return null;
    return _fileNode(clean, rootPath: rootPath);
  }

  @override
  Future<LocalChessOpeningTreeRebuildResult?>
  rebuildOpeningTreeFromCachedGames({
    required String databasePath,
    LocalChessScanProgressSink? onProgress,
  }) async {
    final clean = databasePath.trim();
    final gameCount = gameCountsByPath[clean];
    if (gameCount == null) return null;
    onProgress?.call(
      LocalChessScanProgress(fraction: 0.5, message: 'Building tree...'),
    );
    final index = _paneTreeIndex(path: clean, gameCount: gameCount);
    indexes[clean] = index;
    onProgress?.call(
      LocalChessScanProgress(fraction: 1, message: 'Tree ready.'),
    );
    return LocalChessOpeningTreeRebuildResult(index: index, skippedGames: 0);
  }

  LocalChessFileNode _fileNode(String path, {required String rootPath}) {
    return LocalChessFileNode(
      name: path.split('/').last,
      path: path,
      relativePath: path == rootPath ? path.split('/').last : path,
      extension: '.pgn',
      status: LocalChessFileStatus.parsed,
      games: const <LocalChessGame>[],
      gameCount: gameCountsByPath[path] ?? 0,
      sizeBytes: 1,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1),
      openingTreeIndex: indexes[path],
    );
  }
}

PlayerOpeningTreeIndex _paneTreeIndex({
  required String path,
  required int gameCount,
}) {
  return PlayerOpeningTreeIndex(
    treeId: 'local:$path',
    playerId: path,
    maxPly: 50,
    rootNodeId: 0,
    generatedAt: DateTime.fromMillisecondsSinceEpoch(1),
    nodesById: const <int, PlayerOpeningTreeNode>{},
    nodesByFenKey: const <String, PlayerOpeningTreeNode>{},
    gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
    gameRowsById: const <String, Map<String, dynamic>>{},
    persistedPositionCount: 1,
    persistedGameCount: gameCount,
  );
}

String _paneTestPgn(String username) {
  return '''
[Event "Pane progress test"]
[Site "https://lichess.org/test"]
[Date "2026.07.07"]
[White "$username"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5 1-0
''';
}
