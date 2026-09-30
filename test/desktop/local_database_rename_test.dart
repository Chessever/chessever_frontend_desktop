import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/my_databases_focus.dart';

class MemoryDatabase implements AppDatabase {
  final values = <String, Object>{};
  bool failRegistryWrite = false;
  @override
  Future<T?> getJson<T>(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key])) as T;
  @override
  Future<void> setJson(String key, Object value) async {
    if (failRegistryWrite && key == 'desktop.local_libraries.v1') {
      throw StateError('disk full');
    }
    values[key] = jsonDecode(jsonEncode(value)) as Object;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'real cache coordinator invalidates old identity and reopens renamed PGN',
    () async {
      final root = await Directory.systemTemp.createTemp('rename-cache-');
      final cache = await resqlite.Database.open('${root.path}/cache.db');
      addTearDown(() async {
        await cache.close();
        await root.delete(recursive: true);
      });
      await createLocalChessResqliteDatabaseSchema(cache);
      final repo = LocalChessDatabaseRepository(database: () async => cache);
      final file = File('${root.path}/old.pgn')..writeAsStringSync(
        '[Event "Rename"]\n[White "A"]\n[Black "B"]\n[Result "*"]\n\n1. e4 e5 *\n',
      );
      final original = await scanLocalChessPaths([file.path]);
      await repo.persistFileNode(
        original.root.singlePlayableDatabaseInSubtree!,
        sourceLabel: original.label,
      );
      final db = MemoryDatabase();
      final registry = LocalLibraryRegistryNotifier(db);
      await registry.register(file.path);
      final library = LocalChessLibraryNotifier(
        registry: registry,
        localDatabaseRepository: repo,
      );
      final renamed = await library.renameRegisteredPgn(
        file.path,
        'savio',
        ensureUnused: () {},
      );
      expect(
        await repo.loadFreshFileNode(file.path, rootPath: root.path),
        isNull,
      );
      final reopened = await scanLocalChessPaths([renamed]);
      final node = reopened.root.singlePlayableDatabaseInSubtree!;
      expect(node.games.single.sourcePath, renamed);
      await repo.persistFileNode(node, sourceLabel: reopened.label);
      expect(
        (await repo.loadFreshFileNode(renamed, rootPath: root.path))?.gameCount,
        1,
      );
      expect(library.state.sessionSources, isEmpty);
      library.dispose();
      registry.dispose();
    },
  );

  test('rename preserves pin position and recency across restart', () async {
    final db = MemoryDatabase();
    final focus = MyDatabasesFocusNotifier(db);
    final oldKey = libraryLocalDatabasePinKey('old.pgn');
    final newKey = libraryLocalDatabasePinKey('new.pgn');
    await focus.pinDatabase('cloud:first');
    await focus.pinDatabase(oldKey);
    await focus.recordSuccessfulOpen(oldKey, openedAt: DateTime.utc(2026));
    await focus.renameLocalDatabase('old.pgn', 'new.pgn');
    focus.dispose();
    final restored = MyDatabasesFocusNotifier(db);
    await restored.loaded;
    expect(restored.state.orderedPinnedDatabaseKeys, ['cloud:first', newKey]);
    expect(restored.state.lastOpenedAtByItemKey[newKey], DateTime.utc(2026));
    expect(restored.state.lastOpenedAtByItemKey.containsKey(oldKey), isFalse);
    restored.dispose();
  });

  test(
    'interrupted move is recovered only by its exact content fingerprint',
    () async {
      final root = await Directory.systemTemp.createTemp('rename-recovery-');
      addTearDown(() => root.delete(recursive: true));
      final from = '${root.path}/old.pgn';
      final to = '${root.path}/new.pgn';
      final file = File(to)..writeAsStringSync('original');
      final db = MemoryDatabase();
      db.values['desktop.local_libraries.v1'] = [
        LocalLibraryEntry(path: from, addedAt: DateTime.utc(2026)).toJson(),
      ];
      db.values['desktop.local_library_rename.v1'] = {
        'from': from,
        'to': to,
        'sha256': sha256.convert(file.readAsBytesSync()).toString(),
      };
      final restored = LocalLibraryRegistryNotifier(db);
      await restored.register(to);
      expect(restored.state.entries.single.path, to);
      restored.dispose();
    },
  );

  test('destination created after validation is never overwritten', () async {
    final root = await Directory.systemTemp.createTemp('rename-race-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/old.pgn')..writeAsStringSync('original');
    final target = File('${root.path}/new.pgn');
    final registry = LocalLibraryRegistryNotifier(MemoryDatabase());
    await registry.register(source.path);
    var checks = 0;
    await expectLater(
      registry.renamePgn(
        source.path,
        'new',
        ensureUnused: () {
          if (++checks == 2) target.writeAsStringSync('neighbor');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.readAsStringSync(), 'original');
    expect(target.readAsStringSync(), 'neighbor');
    expect(registry.state.entries.single.path, source.path);
    registry.dispose();
  });

  test(
    'rename preserves bytes and metadata and reopens after hydration',
    () async {
      final root = await Directory.systemTemp.createTemp('rename-pgn-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/database.pgn');
      await source.writeAsString('[Event "Analysis"]\n\n1. e4 *\n');
      final bytes = await source.readAsBytes();
      final cbh = File('${root.path}/database.cbh')
        ..writeAsStringSync('original');
      final db = MemoryDatabase();
      final registry = LocalLibraryRegistryNotifier(db);
      await registry.registerAll(
        [source.path],
        metadataByPath: {
          source.path: const LocalLibraryEntryMetadata(gameCount: 1),
        },
      );
      final addedAt = registry.state.entries.single.addedAt;
      final renamed = await registry.renamePgn(source.path, 'Savio Games');
      expect(File(renamed).uri.pathSegments.last, 'Savio Games.pgn');
      expect(await File(renamed).readAsBytes(), bytes);
      expect(await source.exists(), isFalse);
      expect(cbh.readAsStringSync(), 'original');
      expect(registry.state.entries.single.gameCount, 1);
      expect(registry.state.entries.single.addedAt, addedAt);
      registry.dispose();
      final reopened = LocalLibraryRegistryNotifier(db);
      await reopened.register(renamed);
      expect(reopened.state.entries.single.path, renamed);
      expect(reopened.state.entries.single.displayName, 'Savio Games.pgn');
      reopened.dispose();
    },
  );

  for (final scenario in [
    'collision',
    'invalid',
    'in-use',
    'persist-failure',
  ]) {
    test('$scenario leaves PGN and registry unchanged', () async {
      final root = await Directory.systemTemp.createTemp('rename-guard-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/old.pgn')
        ..writeAsStringSync('original');
      final target = File('${root.path}/new.pgn');
      final db = MemoryDatabase();
      final registry = LocalLibraryRegistryNotifier(db);
      await registry.register(source.path);
      if (scenario == 'collision') target.writeAsStringSync('neighbor');
      db.failRegistryWrite = scenario == 'persist-failure';
      await expectLater(
        registry.renamePgn(
          source.path,
          scenario == 'invalid' ? '../escape' : 'new',
          ensureUnused: () {
            if (scenario == 'in-use') throw StateError('Open Board');
          },
        ),
        throwsA(anything),
      );
      expect(source.readAsStringSync(), 'original');
      expect(registry.state.entries.single.path, source.path);
      expect(target.existsSync(), scenario == 'collision');
      if (target.existsSync()) expect(target.readAsStringSync(), 'neighbor');
      registry.dispose();
    });
  }
}
