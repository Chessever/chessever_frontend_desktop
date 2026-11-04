import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgn = '[Event "Import"]\n[Result "1-0"]\n\n1. e4 e5 1-0';

class _RegistryDatabase implements AppDatabase {
  _RegistryDatabase(this.entries);

  List<dynamic> entries;
  final release = Completer<void>();

  @override
  Future<T?> getJson<T>(String key) async {
    if (key != 'desktop.local_libraries.v1') return null;
    await release.future;
    return entries as T;
  }

  @override
  Future<void> setJson(String key, Object value) async {
    if (key == 'desktop.local_libraries.v1') entries = value as List<dynamic>;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('web_pgn_admission_');
  });

  tearDown(() async => directory.delete(recursive: true));

  test(
    'declined direct file intake leaves current state and source untouched',
    () async {
      var prompts = 0;
      final notifier = LocalChessLibraryNotifier(
        requestImportAccess: () async {
          prompts++;
          return false;
        },
      );
      addTearDown(notifier.dispose);
      final before = notifier.state;

      expect(
        await notifier.openPaths(['${directory.path}/missing.pgn']),
        isFalse,
      );
      expect(prompts, 1);
      expect(notifier.state, same(before));
      expect(notifier.state.error, isNull);
      expect(notifier.state.isScanning, isFalse);
    },
  );

  test('picker denial returns before opening either system picker', () async {
    var prompts = 0;
    final notifier = LocalChessLibraryNotifier(
      requestImportAccess: () async {
        prompts++;
        return false;
      },
    );
    addTearDown(notifier.dispose);

    // No FilePicker platform is installed. Reaching it would fail this test.
    expect(await notifier.pickFiles(), isFalse);
    expect(await notifier.pickFolder(), isFalse);
    expect(prompts, 2);
    expect(notifier.state.source, isNull);
  });

  test(
    'a retained session reopens and refreshes after Premium lapses',
    () async {
      final file = File('${directory.path}/retained.pgn');
      await file.writeAsString(_pgn);
      var premium = true;
      var prompts = 0;
      final notifier = LocalChessLibraryNotifier(
        requestImportAccess: () async {
          prompts++;
          return premium;
        },
      );
      addTearDown(notifier.dispose);

      expect(await notifier.openPaths([file.path]), isTrue);
      premium = false;
      expect(await notifier.openPaths([file.path]), isTrue);
      await notifier.refresh();
      expect(prompts, 1);
      expect(notifier.state.source, isNotNull);

      final current = notifier.state.source;
      expect(await notifier.openPaths(['${directory.path}/new.pgn']), isFalse);
      expect(notifier.state.source, same(current));
      expect(prompts, 2);
    },
  );

  test(
    'restored databases await registry hydration and never prompt',
    () async {
      final file = File('${directory.path}/retained.pgn');
      await file.writeAsString(_pgn);
      final database = _RegistryDatabase([
        {'path': file.path, 'addedAt': '2026-11-05T00:00:00.000'},
      ]);
      final registry = LocalLibraryRegistryNotifier(database);
      addTearDown(registry.dispose);
      var prompts = 0;
      final notifier = LocalChessLibraryNotifier(
        registry: registry,
        requestImportAccess: () async {
          prompts++;
          return false;
        },
      );
      addTearDown(notifier.dispose);

      final opening = notifier.openPaths([file.path]);
      await Future<void>.delayed(Duration.zero);
      expect(prompts, 0);
      expect(notifier.state.source, isNull);
      database.release.complete();

      expect(await opening, isTrue);
      expect(prompts, 0);
      expect(notifier.state.source, isNotNull);
    },
  );
}
