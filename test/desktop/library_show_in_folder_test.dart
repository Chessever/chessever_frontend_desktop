import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/services/local_path_reveal.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/library/local_database_show_in_folder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

/// Menu-level regression guard for `Show in folder`:
///  - a local database row offers the action and it dispatches,
///  - a cloud database row never offers it (there is no file on this PC),
///  - a database whose file is gone reports the exact path instead of opening
///    an unrelated folder,
///  - both Library surfaces (the Home row menu and the open database header)
///    are wired to the real reveal path.
enum _TestAction { reveal, other }

void main() {
  group('show in folder availability', () {
    test('a local database with a real file path offers the action', () {
      expect(
        libraryDatabaseShowsShowInFolder(
          isCloudDatabase: false,
          localPath: r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
        ),
        isTrue,
      );
    });

    test('a cloud database never offers the action, even with a stray path', () {
      expect(
        libraryDatabaseShowsShowInFolder(
          isCloudDatabase: true,
          localPath: r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
        ),
        isFalse,
      );
      expect(
        libraryDatabaseShowsShowInFolder(
          isCloudDatabase: false,
          localPath: '   ',
        ),
        isFalse,
      );
      expect(
        libraryDatabaseShowsShowInFolder(
          isCloudDatabase: false,
          localPath: null,
        ),
        isFalse,
      );
    });

    test('the menu entry carries the shared label and the row action value', () {
      final entry = localDatabaseShowInFolderMenuItem<_TestAction>(
        value: _TestAction.reveal,
        localPath: r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
      );

      expect(entry, isNotNull);
      expect(entry!.label, kLocalDatabaseShowInFolderLabel);
      expect(entry.label, 'Show in folder');
      expect(entry.value, _TestAction.reveal);
      expect(entry.enabled, isTrue);
      expect(entry.destructive, isFalse);
    });

    test('a cloud row produces no menu entry at all', () {
      expect(
        localDatabaseShowInFolderMenuItem<_TestAction>(
          value: _TestAction.reveal,
          localPath: r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
          isCloudDatabase: true,
        ),
        isNull,
      );
    });
  });

  group('menu rendering', () {
    Future<void> pumpMenuHost(
      WidgetTester tester, {
      required void Function(BuildContext context) onOpen,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => onOpen(context),
                child: const Text('open menu'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a local database row renders and dispatches Show in folder',
        (tester) async {
      _TestAction? picked;
      await pumpMenuHost(
        tester,
        onOpen: (context) {
          final entry = localDatabaseShowInFolderMenuItem<_TestAction>(
            value: _TestAction.reveal,
            localPath: r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
          );
          unawaited(
            showDesktopContextMenu<_TestAction>(
              context: context,
              position: Offset.zero,
              width: 260,
              entries: <DesktopContextMenuEntry<_TestAction>>[
                const DesktopContextMenuItem<_TestAction>(
                  value: _TestAction.other,
                  icon: Icons.table_rows_outlined,
                  label: 'Preview database',
                ),
                if (entry != null) entry,
              ],
            ).then((value) => picked = value),
          );
        },
      );

      await tester.tap(find.text('open menu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Preview database'), findsOneWidget);
      expect(find.text('Show in folder'), findsOneWidget);

      await tester.tap(find.text('Show in folder'));
      await tester.pump();
      expect(picked, _TestAction.reveal);
    });

    testWidgets('a cloud database row renders no Show in folder', (
      tester,
    ) async {
      await pumpMenuHost(
        tester,
        onOpen: (context) {
          final entry = localDatabaseShowInFolderMenuItem<_TestAction>(
            value: _TestAction.reveal,
            localPath: r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
            isCloudDatabase: true,
          );
          unawaited(
            showDesktopContextMenu<_TestAction>(
              context: context,
              position: Offset.zero,
              width: 260,
              entries: <DesktopContextMenuEntry<_TestAction>>[
                const DesktopContextMenuItem<_TestAction>(
                  value: _TestAction.other,
                  icon: Icons.table_rows_outlined,
                  label: 'Preview database',
                ),
                if (entry != null) entry,
              ],
            ),
          );
        },
      );

      await tester.tap(find.text('open menu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Preview database'), findsOneWidget);
      expect(find.text('Show in folder'), findsNothing);
    });
  });

  group('missing file message', () {
    testWidgets('a deleted database names its exact path in the toast', (
      tester,
    ) async {
      LocalPathRevealResult? outcome;
      var launches = 0;
      await tester.pumpWidget(
        FTheme(
          data: FThemes.zinc.dark,
          child: FToaster(
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      outcome = await revealLocalDatabasePath(
                        context,
                        r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
                        isWindows: true,
                        isMacOS: false,
                        isLinux: false,
                        pathExists: (_) async => false,
                        runCommand: (_) async {
                          launches++;
                          return true;
                        },
                        runWindowsReveal: (_) {
                          launches++;
                          return true;
                        },
                      );
                    },
                    child: const Text('show in folder'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('show in folder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(outcome, isNotNull);
      expect(outcome!.outcome, LocalPathRevealOutcome.missingFile);
      expect(launches, 0);
      expect(
        find.text(
          r'That database file is no longer on this computer: '
          r'C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn',
        ),
        findsOneWidget,
      );

      // Flush forui's auto-dismiss timer so teardown sees no pending Timer.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a successful reveal shows no error toast', (tester) async {
      LocalPathRevealResult? outcome;
      await tester.pumpWidget(
        FTheme(
          data: FThemes.zinc.dark,
          child: FToaster(
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      outcome = await revealLocalDatabasePath(
                        context,
                        '/home/vasif/Lesson Plans.pgn',
                        isWindows: false,
                        isMacOS: true,
                        isLinux: false,
                        pathExists: (_) async => true,
                        runCommand: (_) async => true,
                      );
                    },
                    child: const Text('reveal'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('reveal'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(outcome!.outcome, LocalPathRevealOutcome.revealed);
      expect(find.textContaining('no longer on this computer'), findsNothing);
    });
  });

  group('library surfaces are wired to the reveal action', () {
    test('the Library Home local row menu offers it and dispatches the path',
        () {
      final source =
          File('lib/desktop/panes/library_pane.dart').readAsStringSync();
      final localMenu = source.substring(
        source.indexOf('Future<void> showLocalContextMenu('),
        source.indexOf('Future<void> removeLocalGroupFromLibraryHome('),
      );
      final cloudMenu = source.substring(
        source.indexOf('Future<void> showCloudContextMenu('),
        source.indexOf('void showCloudFolderContextMenu('),
      );

      expect(localMenu, contains('_LocalDatabaseBoardAction.showInFolder'));
      expect(
        localMenu,
        contains('localDatabaseShowInFolderMenuItem<'),
      );
      expect(localMenu, contains('localPath: entry.path'));
      expect(
        localMenu,
        contains('await revealLocalRecordPath(context, entry.path)'),
      );
      // The reveal uses the record's path, not a display-name guess.
      expect(localMenu, contains('localPath: entry.path'));
      // Cloud rows have no local file: their menu must not offer the action.
      expect(cloudMenu, isNot(contains('Show in folder')));
      expect(cloudMenu, isNot(contains('showInFolder')));
    });

    test('the open database header offers it for the selected file', () {
      final source = File(
        'lib/desktop/widgets/library/local_chess_files_view.dart',
      ).readAsStringSync();
      final header = source.substring(
        source.indexOf('class _LocalHeader extends StatelessWidget {'),
        source.indexOf('class _HeaderAction extends StatelessWidget {'),
      );

      expect(header, contains('kLocalDatabaseShowInFolderLabel'));
      expect(header, contains('selectedLocalChessDatabaseFile(node)'));
      expect(source, contains('revealLocalDatabasePath('));
      expect(source, contains('selectedDatabase.path'));
    });
  });
}
