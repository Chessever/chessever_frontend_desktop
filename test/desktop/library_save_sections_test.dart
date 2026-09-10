import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/my_databases_focus.dart';
import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/desktop/widgets/library/library_save_section.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart';

LibraryFolder folder(
  String id, {
  String icon = 'database',
  bool subscribed = false,
}) => LibraryFolder(
  id: id,
  userId: 'user',
  // Intentionally system-looking display text: names must not decide eligibility.
  name: 'ChessEver',
  color: '#0FB4E5',
  icon: icon,
  orderIndex: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  isSubscribed: subscribed,
);

void main() {
  test(
    'pins retain canonical mixed order, reject system/generated and stale keys',
    () {
      final local = LocalLibraryEntry(
        path: 'Combined.pgn',
        addedAt: DateTime(2026),
      );
      final generated = LocalLibraryEntry(
        path: 'ordinary.pgn',
        addedAt: DateTime(2026),
        playerWorkspaceSource: 'combined',
      );
      final grouped = LocalLibraryEntry(
        path: 'other.pgn',
        addedAt: DateTime(2026),
        groupId: 'player-workspace:123',
      );
      final readOnly = LocalLibraryEntry(
        path: 'archive.cbh',
        addedAt: DateTime(2026),
      );
      final keys = [
        libraryLocalDatabasePinKey(local.path),
        'cloud:second',
        'cloud:__twic__',
        'cloud:shared',
        'cloud:container',
        libraryLocalDatabasePinKey(generated.path),
        libraryLocalDatabasePinKey(grouped.path),
        libraryLocalDatabasePinKey(readOnly.path),
        'group:123',
        'cloud:missing',
        'cloud:first',
        'cloud:second',
      ];
      List<String> resolve(LibrarySaveDestinationMode mode) =>
          librarySavePinnedDestinationKeys(
            orderedPinKeys: keys,
            folders: [
              folder('first'),
              folder('second'),
              kTwicFolder,
              folder('shared', subscribed: true),
              folder('container', icon: 'folder_container'),
            ],
            localEntries: [local, generated, grouped, readOnly],
            destinationMode: mode,
          );
      expect(resolve(LibrarySaveDestinationMode.cloudAndLocal), [
        keys.first,
        'cloud:second',
        'cloud:first',
      ]);
      expect(resolve(LibrarySaveDestinationMode.cloudOnly), [
        'cloud:second',
        'cloud:first',
      ]);
      expect(resolve(LibrarySaveDestinationMode.localOnly), [keys.first]);
    },
  );

  testWidgets(
    'disclosure supports Tab, Enter and Space without activating children',
    (tester) async {
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibrarySaveSection(
              label: 'PINNED',
              icon: Icons.push_pin_outlined,
              children: [
                DesktopTappable(
                  onPress: () => activations++,
                  child: const Text('destination'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('destination'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('destination'), findsOneWidget);
      expect(activations, 0);
    },
  );

  testWidgets(
    'actual dialog aliases share selection; independent collapse and Cancel never write',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = _ReadOnlyFixtureDatabase();
      var repositoryReads = 0;
      var updates = 0;
      LibrarySaveOutcome? outcome;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryFoldersStreamProvider.overrideWith(
              (ref) => Stream.value([folder('cloud')]),
            ),
            myDatabasesFocusProvider.overrideWith(
              (ref) => MyDatabasesFocusNotifier(db),
            ),
            localLibraryRegistryProvider.overrideWith(
              (ref) => LocalLibraryRegistryNotifier(db),
            ),
            libraryRepositoryProvider.overrideWith((ref) {
              repositoryReads++;
              throw StateError('No repository access allowed before Save');
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder:
                    (context, ref, _) => DesktopTappable(
                      onPress:
                          () => unawaited(
                            showLibrarySaveToFolderDialog(
                              context: context,
                              ref: ref,
                              games: [
                                ChessGame(
                                  gameId: 'fixture',
                                  startingFen: '',
                                  metadata: {},
                                  mainline: [],
                                ),
                              ],
                              updateTarget: LibraryUpdateTarget(
                                title: 'Original',
                                subtitle: 'Cloud library',
                                onUpdate: (_) async {
                                  updates++;
                                },
                              ),
                            ).then((value) => outcome = value),
                          ),
                      child: const Text('Open'),
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      Finder section(String key) => find.byKey(ValueKey(key));
      Finder inside(String key, String text) =>
          find.descendant(of: section(key), matching: find.text(text));
      expect(find.byType(LibrarySaveSection), findsNWidgets(3));
      expect(
        tester.getTopLeft(section('save-pinned')).dy,
        lessThan(tester.getTopLeft(section('save-cloud')).dy),
      );
      await tester.tap(inside('save-pinned', 'ChessEver'));
      await tester.pumpAndSettle();
      expect(find.text('Save to 1 destination'), findsOneWidget);
      // Toggle the underlying alias off: it must not create a second selection.
      await tester.tap(inside('save-cloud', 'ChessEver'));
      await tester.pumpAndSettle();
      expect(find.text('Pick a destination'), findsOneWidget);
      await tester.tap(inside('save-cloud', 'ChessEver'));
      await tester.pumpAndSettle();
      await tester.tap(inside('save-pinned', 'PINNED'));
      await tester.tap(inside('save-cloud', 'CLOUD LIBRARY'));
      await tester.pumpAndSettle();
      expect(find.text('Save to 1 destination'), findsOneWidget);
      expect(find.text('1 selected'), findsNWidgets(2));
      expect(find.text('Update existing game'), findsOneWidget);
      expect(inside('save-local', 'local.pgn').first, findsOneWidget);
      await tester.tap(inside('save-local', 'local.pgn').first);
      await tester.pumpAndSettle();
      expect(find.text('Save to 2 destinations'), findsOneWidget);
      await tester.tap(inside('save-pinned', 'PINNED'));
      await tester.pumpAndSettle();
      await tester.tap(inside('save-pinned', 'local.pgn').first);
      await tester.pumpAndSettle();
      expect(find.text('Save to 1 destination'), findsOneWidget);
      expect(inside('save-cloud', 'ChessEver'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(outcome, isNull);
      expect(repositoryReads, 0);
      expect(updates, 0);
      expect(db.writes, 0);
    },
  );
}

class _ReadOnlyFixtureDatabase implements AppDatabase {
  int writes = 0;

  @override
  Future<T?> getJson<T>(String key) async {
    final Object? value = switch (key) {
      'desktop.my_databases.focus.v2' => {
        'version': 2,
        'orderedPinnedDatabaseKeys': [
          'cloud:cloud',
          libraryLocalDatabasePinKey('local.pgn'),
        ],
        'pinnedOrderCustomized': true,
      },
      'desktop.local_libraries.v1' => <dynamic>[
        LocalLibraryEntry(path: 'local.pgn', addedAt: DateTime(2026)).toJson(),
      ],
      _ => null,
    };
    return value as T?;
  }

  @override
  Future<void> setJson(String key, Object value) async {
    writes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
