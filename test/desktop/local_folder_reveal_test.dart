import 'dart:io';

import 'package:chessever/desktop/services/local_path_reveal.dart';
import 'package:chessever/desktop/widgets/library/local_database_show_in_folder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for `Show in folder` on FOLDERS:
///  - the directory command shape per platform (the folder itself, never
///    `/select,` semantics),
///  - spaces / unicode / shell metacharacters stay inside one argument (or one
///    verbatim shell fragment) and are never rewritten,
///  - a missing folder names its exact path instead of opening anything,
///  - a relative record is resolved to an absolute path first,
///  - the menu entry exists for a local folder and never for a cloud folder,
///  - the Library surfaces are wired to the folder action.
enum _TestFolderAction { reveal }

void main() {
  const windowsFolder = r'C:\Users\Vasif\My Databases';
  const windowsFolderWithSpace = r'C:\Users\Vasif\My Databases\Club Games';

  group('directory reveal — Windows shell request', () {
    test('opens the folder itself with no /select fragment', () {
      final request = windowsDirectoryRevealRequest(windowsFolderWithSpace);

      expect(request.executable, 'explorer.exe');
      expect(request.parameters, '"$windowsFolderWithSpace"');
      expect(request.parameters.startsWith('"'), isTrue);
      expect(request.parameters.endsWith('"'), isTrue);
      expect(request.parameters, isNot(contains('/select')));
      // Literal quotes only: a backslash-escaped quote is the argv shape
      // Explorer rejects, so it must never appear here.
      expect(request.parameters, isNot(contains(r'\"')));
    });

    test('normalizes forward slashes but never rewrites the path itself', () {
      expect(
        windowsDirectoryRevealRequest(
          'C:/Users/Vasif/My Databases',
        ).parameters,
        r'"C:\Users\Vasif\My Databases"',
      );
      expect(
        windowsDirectoryRevealRequest(r'\\server\share\games').parameters,
        r'"\\server\share\games"',
      );
    });

    test('Windows contributes no POSIX argv command for a directory', () {
      expect(
        localPathDirectoryRevealCommands(
          path: windowsFolder,
          isWindows: true,
          isMacOS: false,
          isLinux: false,
        ),
        isEmpty,
      );
    });
  });

  group('directory reveal — POSIX argv commands', () {
    test('macOS opens the folder with one raw argv element', () {
      const path = '/Users/vasif/My Databases/Şah Mat';
      final command = localPathDirectoryRevealCommands(
        path: path,
        isWindows: false,
        isMacOS: true,
        isLinux: false,
      ).single;

      expect(command.executable, 'open');
      expect(command.arguments, <String>[path]);
    });

    test('Linux opens the folder with xdg-open', () {
      const path = '/home/vasif/My Databases/Şah Mat';
      final command = localPathDirectoryRevealCommands(
        path: path,
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      ).single;

      expect(command.executable, 'xdg-open');
      expect(command.arguments, <String>[path]);
    });

    test('shell metacharacters stay inside the single argument', () {
      const path = r'/home/vasif/Games & Stuff; rm -rf ~';
      final command = localPathDirectoryRevealCommands(
        path: path,
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      ).single;

      expect(command.arguments, hasLength(1));
      expect(command.arguments.single, path);
    });

    test('an empty path or unknown platform builds no command', () {
      expect(
        localPathDirectoryRevealCommands(
          path: '   ',
          isWindows: false,
          isMacOS: true,
          isLinux: false,
        ),
        isEmpty,
      );
      expect(
        localPathDirectoryRevealCommands(
          path: '/games',
          isWindows: false,
          isMacOS: false,
          isLinux: false,
        ),
        isEmpty,
      );
    });
  });

  group('revealLocalPathInFileManager with a directory target', () {
    test('Windows hands the plain folder fragment to the shell', () async {
      final requests = <WindowsRevealRequest>[];
      final result = await revealLocalPathInFileManager(
        windowsFolderWithSpace,
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        target: LocalPathRevealTarget.directory,
        pathExists: (_) async => true,
        runCommand: (_) async => fail('Windows must not use a POSIX command'),
        runWindowsReveal: (request) {
          requests.add(request);
          return true;
        },
      );

      expect(result.outcome, LocalPathRevealOutcome.revealed);
      expect(result.message, isNull);
      expect(requests.single.executable, 'explorer.exe');
      expect(requests.single.parameters, '"$windowsFolderWithSpace"');
    });

    test('the file target keeps the shipped /select fragment', () async {
      final requests = <WindowsRevealRequest>[];
      await revealLocalPathInFileManager(
        r'C:\Users\Vasif\My Databases\Club Games.pgn',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        pathExists: (_) async => true,
        runWindowsReveal: (request) {
          requests.add(request);
          return true;
        },
      );

      expect(
        requests.single.parameters,
        r'/select,"C:\Users\Vasif\My Databases\Club Games.pgn"',
      );
    });

    test('macOS launches the folder command verbatim', () async {
      final launched = <LocalPathRevealCommand>[];
      final result = await revealLocalPathInFileManager(
        '/Users/vasif/My Databases/Şah Mat',
        isWindows: false,
        isMacOS: true,
        isLinux: false,
        target: LocalPathRevealTarget.directory,
        pathExists: (_) async => true,
        runCommand: (command) async {
          launched.add(command);
          return true;
        },
      );

      expect(result.outcome, LocalPathRevealOutcome.revealed);
      expect(launched.single.executable, 'open');
      expect(launched.single.arguments, <String>[
        '/Users/vasif/My Databases/Şah Mat',
      ]);
    });

    test('a missing folder names the exact path and launches nothing', () async {
      var launches = 0;
      final result = await revealLocalPathInFileManager(
        r'C:\Users\Vasif\Removed Folder',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        target: LocalPathRevealTarget.directory,
        pathExists: (_) async => false,
        runWindowsReveal: (_) {
          launches++;
          return true;
        },
      );

      expect(result.outcome, LocalPathRevealOutcome.missingFile);
      expect(result.revealed, isFalse);
      expect(result.message, contains(r'C:\Users\Vasif\Removed Folder'));
      expect(result.message, contains('no longer on this computer'));
      expect(launches, 0);
    });

    test('a refused shell call reports the path instead of claiming success',
        () async {
      final result = await revealLocalPathInFileManager(
        windowsFolder,
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        target: LocalPathRevealTarget.directory,
        pathExists: (_) async => true,
        runWindowsReveal: (_) => false,
      );

      expect(result.outcome, LocalPathRevealOutcome.failed);
      expect(result.message, contains(windowsFolder));
    });

    test('a relative record resolves against the working directory', () async {
      final requests = <WindowsRevealRequest>[];
      final result = await revealLocalPathInFileManager(
        r'My Databases',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        target: LocalPathRevealTarget.directory,
        currentDirectory: r'C:\Users\Vasif',
        pathExists: (_) async => true,
        runWindowsReveal: (request) {
          requests.add(request);
          return true;
        },
      );

      expect(result.path, r'C:\Users\Vasif\My Databases');
      expect(requests.single.parameters, r'"C:\Users\Vasif\My Databases"');
    });

    test('an absolute unicode path is passed through unchanged', () async {
      const path = r'C:\Kullanıcılar\Vasıf\Şah Mat & Test';
      final requests = <WindowsRevealRequest>[];
      final result = await revealLocalPathInFileManager(
        path,
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        target: LocalPathRevealTarget.directory,
        currentDirectory: r'C:\somewhere\else',
        pathExists: (_) async => true,
        runWindowsReveal: (request) {
          requests.add(request);
          return true;
        },
      );

      expect(result.path, path);
      expect(requests.single.parameters, '"$path"');
      expect(requests.single.parameters, contains('Şah Mat'));
    });

    test('an empty value is unavailable, not a crash', () async {
      final result = await revealLocalPathInFileManager(
        '   ',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        target: LocalPathRevealTarget.directory,
        pathExists: (_) async => true,
        runWindowsReveal: (_) => true,
      );

      expect(result.outcome, LocalPathRevealOutcome.unavailable);
      expect(result.message, localPathRevealUnavailableMessage());
    });
  });

  group('reveal target resolution', () {
    test('a directory path reveals the folder itself', () {
      expect(
        localRevealTargetForPath(r'C:\Games', isDirectory: (_) => true),
        LocalPathRevealTarget.directory,
      );
    });

    test('a file path keeps the file reveal', () {
      expect(
        localRevealTargetForPath(r'C:\Games\a.pgn', isDirectory: (_) => false),
        LocalPathRevealTarget.file,
      );
    });

    test('an empty or uninspectable path falls back to the file reveal', () {
      expect(localRevealTargetForPath(''), LocalPathRevealTarget.file);
      expect(
        localRevealTargetForPath(
          r'C:\Games',
          isDirectory: (_) => throw const FileSystemException('denied'),
        ),
        LocalPathRevealTarget.file,
      );
    });
  });

  group('group folder derivation', () {
    test('records that share a folder resolve to that folder', () {
      expect(
        localLibraryGroupFolderPath(<String>[
          r'C:\Players\GM Vasif\COMBINED_1.pgn',
          r'C:\Players\GM Vasif\CHESSEVER_1.pgn',
        ]),
        r'C:\Players\GM Vasif',
      );
      // Separator style and drive-letter case must not split the group.
      expect(
        localLibraryGroupFolderPath(<String>[
          r'C:\Players\GM Vasif\a.pgn',
          'c:/Players/GM Vasif/b.pgn',
        ]),
        r'C:\Players\GM Vasif',
      );
    });

    test('records in different folders have no single folder', () {
      expect(
        localLibraryGroupFolderPath(<String>[
          r'C:\Players\GM Vasif\a.pgn',
          r'C:\Downloads\b.pgn',
        ]),
        isNull,
      );
      expect(localLibraryGroupFolderPath(const <String>[]), isNull);
      expect(localLibraryGroupFolderPath(<String>['a.pgn']), isNull);
    });

    test('a bare drive keeps its separator', () {
      expect(localLibraryPathParent(r'C:\x.pgn'), r'C:\');
    });
  });

  group('folder menu availability', () {
    test('a local folder with a real path offers the action', () {
      expect(
        libraryFolderShowsShowInFolder(
          isCloudFolder: false,
          localPath: windowsFolder,
        ),
        isTrue,
      );
    });

    test('a cloud folder never offers it', () {
      expect(
        libraryFolderShowsShowInFolder(
          isCloudFolder: true,
          localPath: windowsFolder,
        ),
        isFalse,
      );
      expect(
        libraryFolderShowsShowInFolder(
          isCloudFolder: false,
          localPath: '   ',
        ),
        isFalse,
      );
      expect(
        libraryFolderShowsShowInFolder(isCloudFolder: false, localPath: null),
        isFalse,
      );
    });

    test('the menu entry carries the shared label and the row value', () {
      final entry = localFolderShowInFolderMenuItem<_TestFolderAction>(
        value: _TestFolderAction.reveal,
        localPath: windowsFolder,
      );

      expect(entry, isNotNull);
      expect(entry!.label, kLocalDatabaseShowInFolderLabel);
      expect(entry.label, 'Show in folder');
      expect(entry.value, _TestFolderAction.reveal);
      expect(entry.enabled, isTrue);
      expect(entry.destructive, isFalse);
    });

    test('a cloud folder produces no menu entry at all', () {
      expect(
        localFolderShowInFolderMenuItem<_TestFolderAction>(
          value: _TestFolderAction.reveal,
          localPath: windowsFolder,
          isCloudFolder: true,
        ),
        isNull,
      );
    });
  });

  group('library surfaces are wired to the folder action', () {
    test('the local folder row menu offers it and opens that folder', () {
      final source = File('lib/desktop/panes/library_pane.dart')
          .readAsStringSync();

      expect(source, contains('_LocalGroupBoardAction.showInFolder'));
      expect(source, contains('localLibraryGroupFolderPath('));
      expect(
        source,
        contains('localFolderShowInFolderMenuItem<_LocalGroupBoardAction>'),
      );
      expect(source, contains('revealLocalFolderPath(context, groupFolder)'));
      // The local database row menu resolves the record's own path kind, so a
      // registered folder opens the folder instead of selecting it.
      expect(source, contains('revealLocalRecordPath(context, entry.path)'));
    });

    test('the cloud folder menu never offers it', () {
      final source = File('lib/desktop/panes/library_pane.dart')
          .readAsStringSync();
      final start = source.indexOf('void showCloudFolderContextMenu(');
      expect(start, greaterThan(0));
      final block = source.substring(start, start + 4000);

      expect(block, isNot(contains('showInFolder')));
      expect(block, isNot(contains('revealLocal')));
      expect(block, isNot(contains('kLocalDatabaseShowInFolderLabel')));
    });

    test('the open-folder header offers it for a folder node', () {
      final source = File(
        'lib/desktop/widgets/library/local_chess_files_view.dart',
      ).readAsStringSync();

      expect(source, contains('onRevealFolder:'));
      expect(
        source,
        contains('revealLocalFolderPath(context, node.path)'),
      );
      expect(source, contains('kLocalDatabaseShowInFolderLabel'));
    });
  });
}
