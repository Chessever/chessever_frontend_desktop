import 'package:chessever/desktop/services/local_path_reveal.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for `Show in folder`: the reveal must be built from the
/// exact absolute path, must keep spaces/unicode inside a single argument,
/// must report a missing file instead of silently opening an unrelated folder,
/// and must keep the Windows shape that Explorer actually honors.
void main() {
  group('windowsRevealRequest', () {
    test('selects the exact file with /select and literal quotes', () {
      const path =
          r'C:\Users\Vasif\ChessEver\COMBINED_13402935_CHESSEVER.pgn';
      final request = windowsRevealRequest(path);

      expect(request.executable, 'explorer.exe');
      expect(
        request.parameters,
        r'/select,"C:\Users\Vasif\ChessEver\COMBINED_13402935_CHESSEVER.pgn"',
      );
    });

    // The literal-quotes shape is not cosmetic. Measured on Windows 11:
    //   "/select,\"<path>\""  (Dart argv escaping of quot;ed path) -> Documents
    //   "/select,<path>"      (argv list, whole argument quoted)     -> Documents
    //   /select,"<path>"      (literal quotes, unquoted fragment)    -> file selected
    // Explorer re-parses its own command line, so this form must not be
    // "simplified" back into a Process.start argv list.
    test('keeps the fragment Explorer honors (never an argv-escaped form)', () {
      const path = r'C:\Users\Vasif\My Databases\Club Games.pgn';
      final parameters = windowsRevealRequest(path).parameters;

      expect(parameters, r'/select,"C:\Users\Vasif\My Databases\Club Games.pgn"');
      expect(parameters.startsWith('/select,"'), isTrue);
      expect(parameters.endsWith('"'), isTrue);
      expect(parameters, isNot(contains(r'\"')));
    });

    test('Windows yields no POSIX argv command', () {
      expect(
        localPathRevealCommands(
          path: r'C:\Chess\x.pgn',
          isWindows: true,
          isMacOS: false,
          isLinux: false,
        ),
        isEmpty,
      );
    });

    test('preserves unicode inside the quoted fragment', () {
      const path = r'C:\Kullanıcılar\Vasıf\Şah Mat\maç kayıtları.pgn';
      final parameters = windowsRevealRequest(path).parameters;

      expect(parameters, '/select,"$path"');
      expect(parameters, contains('Şah Mat'));
    });

    test('normalizes drive paths but never a POSIX-looking value', () {
      expect(
        windowsRevealPath('C:/Users/Vasif/My Databases/x.pgn'),
        r'C:\Users\Vasif\My Databases\x.pgn',
      );
      expect(
        windowsRevealPath(r'\\server\share\x.pgn'),
        r'\\server\share\x.pgn',
      );
      expect(windowsRevealPath('databases/local.pgn'), 'databases/local.pgn');
      expect(windowsRevealPath('  D:/chess/x.pgn  '), r'D:\chess\x.pgn');
    });

    test('shell metacharacters stay inside the fragment verbatim', () {
      const path = r'C:\Games\a & b; del *.pgn\weird.pgn';
      final parameters = windowsRevealRequest(path).parameters;

      expect(parameters, contains(path));
      expect(parameters.startsWith('/select,"'), isTrue);
    });
  });

  group('localPathRevealCommands (macOS / Linux)', () {
    test('macOS reveals with open -R and one raw argv element', () {
      const path = '/Users/vasif/My Databases/Şah Mat.pgn';
      final command = localPathRevealCommands(
        path: path,
        isWindows: false,
        isMacOS: true,
        isLinux: false,
      ).single;

      expect(command.executable, 'open');
      // The path stays exactly one argument: no shell word splitting on the
      // space, so Finder gets the whole path verbatim.
      expect(command.arguments, <String>['-R', path]);
    });

    test('Linux opens the containing directory as a best effort', () {
      const path = '/home/vasif/My Databases/Şah Mat.pgn';
      final command = localPathRevealCommands(
        path: path,
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      ).single;

      expect(command.executable, 'xdg-open');
      expect(command.arguments, <String>['/home/vasif/My Databases']);
    });

    test('an empty path or unknown platform builds no command', () {
      expect(
        localPathRevealCommands(
          path: '   ',
          isWindows: false,
          isMacOS: true,
          isLinux: false,
        ),
        isEmpty,
      );
      expect(
        localPathRevealCommands(
          path: '/chess/x.pgn',
          isWindows: false,
          isMacOS: false,
          isLinux: false,
        ),
        isEmpty,
      );
    });

    test('Linux parent directory handles root, trailing and bare names', () {
      expect(posixParentDirectory('/games.pgn'), '/');
      expect(posixParentDirectory('/home/vasif/'), '/home/vasif');
      expect(posixParentDirectory('games.pgn'), '.');
      expect(posixParentDirectory('/home/vasif/  '), '/home/vasif');
    });
  });

  group('revealLocalPathInFileManager', () {
    test('Windows hands the literal-quoted select fragment to the shell', () async {
      final requests = <WindowsRevealRequest>[];
      final result = await revealLocalPathInFileManager(
        r'C:\Users\Vasif\My Databases\Club Games.pgn',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        pathExists: (_) async => true,
        runCommand: (_) async => fail('Windows must not use a POSIX command'),
        runWindowsReveal: (request) {
          requests.add(request);
          return true;
        },
      );

      expect(result.outcome, LocalPathRevealOutcome.revealed);
      expect(result.message, isNull);
      expect(requests, hasLength(1));
      expect(requests.single.executable, 'explorer.exe');
      expect(
        requests.single.parameters,
        r'/select,"C:\Users\Vasif\My Databases\Club Games.pgn"',
      );
    });

    test('normalizes a forward-slash Windows path before revealing it', () async {
      final requests = <WindowsRevealRequest>[];
      await revealLocalPathInFileManager(
        'C:/Users/Vasif/ChessEver/COMBINED_13402935.pgn',
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
        r'/select,"C:\Users\Vasif\ChessEver\COMBINED_13402935.pgn"',
      );
    });

    test('a missing file names the exact path and reveals nothing', () async {
      var launches = 0;
      final result = await revealLocalPathInFileManager(
        r'C:\Users\Vasif\ChessEver\Gone.pgn',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        pathExists: (_) async => false,
        runWindowsReveal: (_) {
          launches++;
          return true;
        },
      );

      expect(result.outcome, LocalPathRevealOutcome.missingFile);
      expect(result.revealed, isFalse);
      expect(result.message, contains(r'C:\Users\Vasif\ChessEver\Gone.pgn'));
      expect(result.message, contains('no longer on this computer'));
      expect(launches, 0);
    });

    test('a shell failure reports the path instead of claiming success', () async {
      final result = await revealLocalPathInFileManager(
        r'C:\Chess\a.pgn',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        pathExists: (_) async => true,
        runWindowsReveal: (_) => false,
      );

      expect(result.outcome, LocalPathRevealOutcome.failed);
      expect(result.message, contains(r'C:\Chess\a.pgn'));
    });

    test('macOS launches the argv command verbatim', () async {
      final launched = <LocalPathRevealCommand>[];
      final result = await revealLocalPathInFileManager(
        '/Users/vasif/My Databases/Club Games.pgn',
        isWindows: false,
        isMacOS: true,
        isLinux: false,
        pathExists: (_) async => true,
        runCommand: (command) async {
          launched.add(command);
          return true;
        },
      );

      expect(result.outcome, LocalPathRevealOutcome.revealed);
      expect(launched, hasLength(1));
      expect(launched.single.executable, 'open');
      expect(launched.single.arguments, <String>[
        '-R',
        '/Users/vasif/My Databases/Club Games.pgn',
      ]);
    });

    test('an empty path is unavailable, not a crash', () async {
      final result = await revealLocalPathInFileManager(
        '   ',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        pathExists: (_) async => true,
        runWindowsReveal: (_) => true,
      );

      expect(result.outcome, LocalPathRevealOutcome.unavailable);
      expect(result.message, localPathRevealUnavailableMessage());
    });
  });

  group('reveal messages', () {
    test('the missing-file message trims and names the path', () {
      expect(
        localPathRevealMissingMessage('  /home/vasif/Lesson Plans.pgn  '),
        'That database file is no longer on this computer: '
        '/home/vasif/Lesson Plans.pgn',
      );
    });

    test('the failure message names the path', () {
      expect(
        localPathRevealFailureMessage(r'C:\Chess\a.pgn'),
        contains(r'C:\Chess\a.pgn'),
      );
    });

    test('the unavailable message explains a cloud database has no file', () {
      expect(localPathRevealUnavailableMessage(), contains('no file'));
      expect(
        localPathRevealUnavailableMessage(),
        isNot(contains('no longer on this computer')),
      );
    });
  });
}
