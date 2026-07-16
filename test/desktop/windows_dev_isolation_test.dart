import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isolated Windows development app', () {
    test('launcher separates runtime state from production', () {
      final launcher =
          File('scripts/run_windows_dev_isolated.ps1').readAsStringSync();
      final builder =
          File('scripts/build_windows_dev_isolated.ps1').readAsStringSync();
      final wrapper =
          File('scripts/run_windows_dev_isolated.cmd').readAsStringSync();

      for (final script in <String>[launcher, builder]) {
        expect(script, contains(r"$env:CHESSEVER_DEV_ISOLATED = '1'"));
        expect(script, contains('ChessEver Development\\Recovered Dev'));
        expect(script, contains('ChessEver Development\\Temp'));
        expect(script, contains('--dart-define=CHESSEVER_DATA_DIR='));
        expect(
          script,
          contains('--dart-define=CHESSEVER_SINGLE_INSTANCE_PORT='),
        );
      }
      expect(wrapper, contains('run_windows_dev_isolated.ps1'));
    });

    test('native build uses a separate executable identity', () {
      final rootCmake = File('windows/CMakeLists.txt').readAsStringSync();
      final runnerCmake =
          File('windows/runner/CMakeLists.txt').readAsStringSync();
      final resources = File('windows/runner/Runner.rc').readAsStringSync();

      expect(rootCmake, contains(r'$ENV{CHESSEVER_DEV_ISOLATED}'));
      expect(rootCmake, contains('set(BINARY_NAME "ChessEverDev")'));
      expect(runnerCmake, contains('CHESSEVER_DEV_ISOLATED'));
      expect(resources, contains('"ChessEverDev.exe"'));
      expect(resources, contains('"ChessEver Development"'));
    });

    test('desktop services consume isolated data and port defines', () {
      final database =
          File('lib/repository/sqlite/app_database.dart').readAsStringSync();
      final fileOpen = File(
        'lib/desktop/services/desktop_file_open_service.dart',
      ).readAsStringSync();
      final identity = File(
        'lib/desktop/services/desktop_build_identity.dart',
      ).readAsStringSync();

      expect(database, contains("'CHESSEVER_DATA_DIR'"));
      expect(fileOpen, contains("'CHESSEVER_SINGLE_INSTANCE_PORT'"));
      expect(identity, contains("'ChessEver Development'"));
      expect(identity, contains('updatesEnabled => isRelease'));
    });
  });
}
