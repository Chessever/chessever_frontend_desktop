import 'dart:async';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/widgets/library/library_cloud_rows.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/library/providers/library_auth_provider.dart';
import 'package:chessever/screens/library/providers/library_cloud_changes_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The open cloud database tab (`Library > Cloud > folder > database`) must not
/// empty its game list while a background refresh runs.
///
/// A cloud Library tab watches `libraryCloudRevisionProvider`, which every
/// cloud change provider bumps on realtime events and on a periodic catch-up.
/// Each bump re-fetches the folder rows. The tab used to treat that refresh as
/// a first load (`connectionState != ConnectionState.done`) and replaced the
/// whole table — including every game row — with a loading placeholder until
/// the fetch returned, which is the intermittent "the game list goes empty and
/// comes back" the user reported.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (_) async => throw StateError('No network in tests'),
      ),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  testWidgets(
    'cloud database tab keeps its loaded games through a cloud refresh',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      final repository = _PendingSavedAnalysesRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repository),
            libraryFolderAuthenticatedUserIdProvider.overrideWithValue(
              'account-a',
            ),
            libraryCloudChangeStreamFactoryProvider.overrideWithValue(
              (_) => changes.stream,
            ),
            databaseWorkspaceArgsByTabIdProvider.overrideWith(
              (ref) => <String, DatabaseWorkspaceArgs>{
                'tab-1': const DatabaseWorkspaceArgs.folder(
                  folderId: 'folder-mehmet',
                  title: 'Mehmet',
                  isSubscribed: false,
                ),
              },
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: DatabaseWorkspacePane(tabId: 'tab-1')),
          ),
        ),
      );

      // First load.
      expect(repository.reads, 1);
      repository.completeNext(<SavedAnalysis>[
        _game('game-1'),
        _game('game-2'),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(libraryDatabaseSavedRowKey('game-1')), findsOneWidget);
      expect(find.byKey(libraryDatabaseSavedRowKey('game-2')), findsOneWidget);

      // A cloud change notification starts a background refresh. The rows must
      // stay mounted for the whole fetch.
      changes.add(null);
      await tester.pump(const Duration(milliseconds: 600));
      expect(repository.reads, 2);
      expect(
        find.byKey(libraryDatabaseSavedRowKey('game-1')),
        findsOneWidget,
        reason: 'a background refresh must not empty the loaded game list',
      );
      expect(find.byKey(libraryDatabaseSavedRowKey('game-2')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // A genuinely new row still appears when the refresh lands.
      repository.completeNext(<SavedAnalysis>[
        _game('game-3'),
        _game('game-1'),
        _game('game-2'),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(libraryDatabaseSavedRowKey('game-3')), findsOneWidget);
      expect(find.byKey(libraryDatabaseSavedRowKey('game-1')), findsOneWidget);
      expect(find.byKey(libraryDatabaseSavedRowKey('game-2')), findsOneWidget);
    },
  );

  testWidgets('a failed background refresh does not empty the game list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    final repository = _PendingSavedAnalysesRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repository),
          libraryFolderAuthenticatedUserIdProvider.overrideWithValue(
            'account-a',
          ),
          libraryCloudChangeStreamFactoryProvider.overrideWithValue(
            (_) => changes.stream,
          ),
          databaseWorkspaceArgsByTabIdProvider.overrideWith(
            (ref) => <String, DatabaseWorkspaceArgs>{
              'tab-1': const DatabaseWorkspaceArgs.folder(
                folderId: 'folder-mehmet',
                title: 'Mehmet',
                isSubscribed: false,
              ),
            },
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DatabaseWorkspacePane(tabId: 'tab-1')),
        ),
      ),
    );

    repository.completeNext(<SavedAnalysis>[_game('game-1')]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(libraryDatabaseSavedRowKey('game-1')), findsOneWidget);

    changes.add(null);
    await tester.pump(const Duration(milliseconds: 600));
    repository.failNext(StateError('temporary network failure'));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(libraryDatabaseSavedRowKey('game-1')),
      findsOneWidget,
      reason: 'a transient refresh failure must not replace loaded rows',
    );
  });
}

class _PendingSavedAnalysesRepository extends LibraryRepository {
  final List<Completer<List<SavedAnalysis>>> _pending =
      <Completer<List<SavedAnalysis>>>[];

  int reads = 0;

  @override
  Future<List<SavedAnalysis>> getSavedAnalyses({
    String? folderId,
    bool? isFavorite,
  }) {
    reads++;
    final completer = Completer<List<SavedAnalysis>>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext(List<SavedAnalysis> rows) =>
      _pending.last.complete(rows);

  void failNext(Object error) => _pending.last.completeError(error);
}

SavedAnalysis _game(String id) => SavedAnalysis(
  id: id,
  userId: 'account-a',
  folderId: 'folder-mehmet',
  title: '$id vs Opponent',
  chessGame: ChessGame(
    gameId: id,
    startingFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    metadata: const <String, dynamic>{
      'White': 'Alpha',
      'Black': 'Beta',
      'Result': '1-0',
    },
    mainline: const <ChessMove>[],
  ),
  analysisState: const <String, dynamic>{},
  variationComments: const <String, String>{},
  lastViewedPosition: 0,
  tags: const <String>[],
  isFavorite: false,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
