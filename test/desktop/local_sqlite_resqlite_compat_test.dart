import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/web/shims/local_sqlite.dart' as localsql;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Users updating from a resqlite build must keep every row.
///
/// The fixture was written by resqlite 0.7.0 through the real import path and
/// copied while its handle was still open, exactly like the cache an app quit
/// leaves behind: the `.db` file is a bare header and every committed row
/// lives only in the `-wal` file. The new driver must replay that WAL, keep the
/// schema markers (a missing cache-generation marker would wipe the cache),
/// and keep serving the data through the repository.
void main() {
  const fixture = 'test/fixtures/local_sqlite/resqlite_0_7_0_live_wal';
  late Directory dir;
  late String dbPath;
  late Map<String, Object?> manifest;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('resqlite_compat_');
    dbPath = p.join(dir.path, 'chessever_local_chess.db');
    for (final suffix in const <String>['', '-wal', '-shm']) {
      final packed = File('$fixture/chessever_local_chess.db$suffix.gz');
      File(
        '$dbPath$suffix',
      ).writeAsBytesSync(gzip.decode(packed.readAsBytesSync()));
    }
    manifest =
        jsonDecode(File('$fixture/manifest.json').readAsStringSync())
            as Map<String, Object?>;
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Map<String, int>> counts(localsql.Database db) async {
    final expected = manifest['counts']! as Map<String, Object?>;
    return <String, int>{
      for (final table in expected.keys)
        table:
            (await db.select('SELECT COUNT(*) AS n FROM $table')).single['n']!
                as int,
    };
  }

  Map<String, int> expectedCounts() => <String, int>{
    for (final entry in (manifest['counts']! as Map<String, Object?>).entries)
      entry.key: entry.value! as int,
  };

  test('the fixture keeps its data only in the WAL', () {
    expect(File(dbPath).lengthSync(), 4096);
    expect(File('$dbPath-wal').lengthSync(), manifest['walBytes']);
  });

  test(
    'opens a resqlite-written live-WAL cache with every row intact',
    () async {
      final db = await localsql.Database.open(dbPath);
      addTearDown(db.close);

      final integrity = await db.select('PRAGMA integrity_check');
      expect(integrity.single.values.single, 'ok');
      expect(await db.select('PRAGMA foreign_key_check'), isEmpty);
      expect(await counts(db), expectedCounts());

      final migrations = await db.select(
        'SELECT name FROM local_chess_migrations ORDER BY name',
      );
      expect(migrations.map((row) => row['name']), manifest['migrations']);
    },
  );

  test(
    'the schema upgrade on open keeps the cache instead of wiping it',
    () async {
      final db = await localsql.Database.open(dbPath);
      addTearDown(db.close);
      for (final pragma in const <String>[
        'PRAGMA foreign_keys=ON',
        'PRAGMA journal_mode=WAL',
        'PRAGMA synchronous=NORMAL',
        'PRAGMA busy_timeout=20000',
        'PRAGMA cache_size=-65536',
      ]) {
        await db.execute(pragma);
      }

      await createLocalChessCacheDatabaseSchema(db);

      expect(await counts(db), expectedCounts());
      final note = await db.select(
        'SELECT notes, is_favorite FROM local_chess_game_analysis '
        'WHERE game_id = ?',
        <Object?>[manifest['analysisGameId']],
      );
      expect(note.single['notes'], 'user note: keep this ♞');
      expect(note.single['is_favorite'], 1);

      final repository = LocalChessDatabaseRepository(database: () async => db);
      final databases = await db.select(
        'SELECT id FROM local_chess_databases ORDER BY id',
      );
      expect(databases, hasLength(2));
      for (final row in databases) {
        final page = await repository.localDatabaseGamesPage(
          databasePath: row['id']! as String,
          pageNumber: 0,
          pageSize: 10,
        );
        expect(page, isNotNull);
        expect(page!.games, hasLength(3));
        expect(
          page.games.map((g) => g.game.metadata['White']).toSet(),
          <String>{'Alpha, Ann', 'Beta, Bob', 'Gamma, Gil'},
        );
      }
    },
  );

  test('new writes persist and a clean close folds the WAL in', () async {
    final db = await localsql.Database.open(dbPath);
    await db.execute(
      'UPDATE local_chess_game_analysis SET notes = ? WHERE game_id = ?',
      <Object?>['edited after the upgrade', manifest['analysisGameId']],
    );
    await db.close();
    expect(File('$dbPath-wal').existsSync(), isFalse);
    expect(File(dbPath).lengthSync(), greaterThan(4096));

    final reopened = await localsql.Database.open(dbPath, readOnly: true);
    addTearDown(reopened.close);
    expect(await counts(reopened), expectedCounts());
    final note = await reopened.select(
      'SELECT notes FROM local_chess_game_analysis WHERE game_id = ?',
      <Object?>[manifest['analysisGameId']],
    );
    expect(note.single['notes'], 'edited after the upgrade');
  });
}
