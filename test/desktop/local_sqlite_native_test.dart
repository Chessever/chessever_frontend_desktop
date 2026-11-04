import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:chessever/web/shims/local_sqlite.dart' as localsql;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Contract tests for the native local SQLite driver
/// (`lib/desktop/services/local_sqlite/local_sqlite_native.dart`).
///
/// They pin the behaviour the local chess cache relies on: connection
/// settings that keep resqlite-written files behaving the same, transaction
/// semantics, read isolation, close/rename safety and error wording.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_sqlite_native_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  String file(String name) => p.join(dir.path, name);

  Future<localsql.Database> openWithTable(String name) async {
    final db = await localsql.Database.open(file(name));
    await db.execute(
      'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, score REAL, data BLOB)',
    );
    return db;
  }

  group('open', () {
    test(
      'creates the file in WAL mode with resqlite-parity settings',
      () async {
        final path = file('new.db');
        final db = await localsql.Database.open(path);
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');

        final header = File(path).readAsBytesSync();
        expect(header[18], 2, reason: 'file format write version: WAL');
        expect(header[19], 2, reason: 'file format read version: WAL');

        final writer = await db.transaction((tx) async {
          Future<Object?> pragma(String name) async =>
              (await tx.select('PRAGMA $name')).single.values.first;
          return <String, Object?>{
            'foreign_keys': await pragma('foreign_keys'),
            'synchronous': await pragma('synchronous'),
            'journal_mode': await pragma('journal_mode'),
            'temp_store': await pragma('temp_store'),
            'busy_timeout': await pragma('busy_timeout'),
          };
        });
        expect(writer['foreign_keys'], 1);
        expect(
          writer['synchronous'],
          1,
          reason: 'NORMAL, as resqlite compiled',
        );
        expect(writer['journal_mode'], 'wal');
        expect(writer['temp_store'], 2);
        expect(writer['busy_timeout'], 20000);

        final readerFk = await db.select('PRAGMA foreign_keys');
        expect(readerFk.single.values.first, 1);
        await db.close();
      },
    );

    test('a missing directory fails with the open-guard wording', () async {
      final path = file(p.join('missing', 'nested', 'x.db'));
      await expectLater(
        localsql.Database.open(path),
        throwsA(
          isA<localsql.LocalSqliteConnectionException>()
              .having(
                (e) => e.message,
                'message',
                startsWith('Failed to open database at "$path"'),
              )
              .having(
                (e) => e.toString(),
                'toString',
                contains('unable to open database file'),
              )
              .having((e) => e.sqliteCode, 'sqliteCode', 14),
        ),
      );
    });

    test(
      'read-only open of a missing file fails instead of creating it',
      () async {
        final path = file('absent.db');
        await expectLater(
          localsql.Database.open(path, readOnly: true),
          throwsA(isA<localsql.LocalSqliteConnectionException>()),
        );
        expect(File(path).existsSync(), isFalse);
      },
    );

    test('a file that is not a database fails at open', () async {
      final path = file('garbage.db');
      File(path).writeAsStringSync('this is not sqlite ' * 400);
      await expectLater(
        localsql.Database.open(path),
        throwsA(
          isA<localsql.LocalSqliteConnectionException>().having(
            (e) => e.message,
            'message',
            startsWith('Failed to open database at'),
          ),
        ),
      );
      await expectLater(
        localsql.Database.open(path, readOnly: true),
        throwsA(isA<localsql.LocalSqliteConnectionException>()),
      );
    });
  });

  group('values', () {
    test('round-trips int, double, text, blob and null', () async {
      final db = await openWithTable('values.db');
      final blob = Uint8List.fromList(<int>[0, 1, 2, 255]);
      final result = await db.execute(
        'INSERT INTO t(id, name, score, data) VALUES (?, ?, ?, ?)',
        <Object?>[1 << 40, 'Ünïcödé ♞', 2.5, blob],
      );
      expect(result.affectedRows, 1);
      expect(result.lastInsertId, 1 << 40);
      await db.execute('INSERT INTO t(id) VALUES (?)', <Object?>[2]);

      final rows = await db.select('SELECT * FROM t ORDER BY id');
      expect(rows.length, 2);
      final first = rows.last;
      expect(first['id'], 1 << 40);
      expect(first['name'], 'Ünïcödé ♞');
      expect(first['score'], 2.5);
      expect(first['data'], blob);
      expect(rows.first['name'], isNull);
      expect(first['no_such_column'], isNull);
      expect(first.keys, <String>['id', 'name', 'score', 'data']);
      expect(() => first['id'] = 3, throwsUnsupportedError);
      expect(rows.sublist(1).single['id'], 1 << 40);
      await db.close();
    });

    test(
      'bool binds as 1/0 and unsupported values throw (never NULL)',
      () async {
        final db = await openWithTable('binds.db');
        await db.execute('INSERT INTO t(id, score) VALUES (?, ?)', <Object?>[
          1,
          true,
        ]);
        expect((await db.select('SELECT score FROM t')).single['score'], 1);
        await expectLater(
          db.execute('INSERT INTO t(id, name) VALUES (?, ?)', <Object?>[
            2,
            DateTime(2026),
          ]),
          throwsA(isA<ArgumentError>()),
        );
        expect((await db.select('SELECT COUNT(*) AS n FROM t')).single['n'], 1);
        await db.close();
      },
    );

    test('duplicate column names resolve to the last occurrence', () async {
      final db = await localsql.Database.open(file('dupes.db'));
      final row = (await db.select('SELECT 1 AS x, 2 AS x')).single;
      expect(row['x'], 2);
      await db.close();
    });
  });

  group('execute', () {
    test('runs several statements when there are no parameters', () async {
      final db = await localsql.Database.open(file('multi.db'));
      await db.execute(
        'CREATE TABLE a(x INTEGER); CREATE INDEX a_x ON a(x); '
        "INSERT INTO a VALUES (1); INSERT INTO a VALUES (2); -- done\n",
      );
      expect((await db.select('SELECT COUNT(*) AS n FROM a')).single['n'], 2);
      await expectLater(
        db.execute(
          'INSERT INTO a VALUES (?); INSERT INTO a VALUES (?)',
          <Object?>[3, 4],
        ),
        throwsA(isA<ArgumentError>()),
      );
      await db.close();
    });

    test('a semicolon inside a string literal is one statement', () async {
      final db = await openWithTable('literal.db');
      await db.execute('INSERT INTO t(id, name) VALUES (?, \'a;b\')', <Object?>[
        1,
      ]);
      expect((await db.select('SELECT name FROM t')).single['name'], 'a;b');
      await db.close();
    });

    test('affectedRows is sqlite3_changes of the statement', () async {
      final db = await openWithTable('changes.db');
      await db.executeBatch('INSERT INTO t(id) VALUES (?)', <List<Object?>>[
        for (var i = 0; i < 10; i++) <Object?>[i],
      ]);
      final updated = await db.execute(
        'UPDATE t SET name = ? WHERE id < ?',
        <Object?>['x', 4],
      );
      expect(updated.affectedRows, 4);
      final deleted = await db.execute('DELETE FROM t WHERE id >= ?', <Object?>[
        5,
      ]);
      expect(deleted.affectedRows, 5);
      await db.close();
    });

    test('foreign keys cascade', () async {
      final db = await localsql.Database.open(file('fk.db'));
      await db.execute(
        'CREATE TABLE parent(id INTEGER PRIMARY KEY); '
        'CREATE TABLE child(id INTEGER PRIMARY KEY, parent_id INTEGER '
        'REFERENCES parent(id) ON DELETE CASCADE)',
      );
      await db.execute('INSERT INTO parent VALUES (1)');
      await db.execute('INSERT INTO child VALUES (10, 1)');
      await db.execute('DELETE FROM parent WHERE id = 1');
      expect(
        (await db.select('SELECT COUNT(*) AS n FROM child')).single['n'],
        0,
      );
      await expectLater(
        db.execute('INSERT INTO child VALUES (11, 99)'),
        throwsA(isA<localsql.LocalSqliteQueryException>()),
      );
      await db.close();
    });

    test('a cached SELECT * sees columns added later', () async {
      final db = await openWithTable('ddl.db');
      await db.execute('INSERT INTO t(id) VALUES (1)');
      expect((await db.select('SELECT * FROM t')).single.keys, hasLength(4));
      await db.transaction((tx) async {
        expect((await tx.select('SELECT * FROM t')).single.keys, hasLength(4));
      });
      await db.execute('ALTER TABLE t ADD COLUMN extra TEXT DEFAULT \'e\'');
      final read = (await db.select('SELECT * FROM t')).single;
      expect(read.keys, contains('extra'));
      expect(read['extra'], 'e');
      await db.transaction((tx) async {
        final row = (await tx.select('SELECT * FROM t')).single;
        expect(row['extra'], 'e');
      });
      await db.close();
    });
  });

  group('executeBatch', () {
    test('is atomic on its own', () async {
      final db = await openWithTable('batch.db');
      await expectLater(
        db.executeBatch('INSERT INTO t(id) VALUES (?)', <List<Object?>>[
          <Object?>[1],
          <Object?>[2],
          <Object?>[1],
        ]),
        throwsA(isA<localsql.LocalSqliteQueryException>()),
      );
      expect((await db.select('SELECT COUNT(*) AS n FROM t')).single['n'], 0);
      await db.executeBatch('INSERT INTO t(id) VALUES (?)', const []);
      await db.close();
    });

    test('ragged parameter rows are rejected', () async {
      final db = await openWithTable('ragged.db');
      await expectLater(
        db.executeBatch(
          'INSERT INTO t(id, name) VALUES (?, ?)',
          <List<Object?>>[
            <Object?>[1, 'a'],
            <Object?>[2],
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
      await db.close();
    });

    test('inside a transaction it adds no transaction of its own', () async {
      final db = await openWithTable('batch_tx.db');
      await db.transaction((tx) async {
        try {
          await tx.executeBatch('INSERT INTO t(id) VALUES (?)', <List<Object?>>[
            <Object?>[1],
            <Object?>[1],
          ]);
        } on localsql.LocalSqliteQueryException {
          // The first row stays applied inside the transaction.
        }
        expect((await tx.select('SELECT COUNT(*) AS n FROM t')).single['n'], 1);
      });
      expect((await db.select('SELECT COUNT(*) AS n FROM t')).single['n'], 1);
      await db.close();
    });

    test('binds 4096 parameters in one statement', () async {
      final db = await openWithTable('wide.db');
      final ids = <Object?>[for (var i = 0; i < 4096; i++) i];
      await db.executeBatch('INSERT INTO t(id) VALUES (?)', <List<Object?>>[
        for (final id in ids) <Object?>[id],
      ]);
      final placeholders = List<String>.filled(ids.length, '?').join(',');
      final rows = await db.select(
        'SELECT COUNT(*) AS n FROM t WHERE id IN ($placeholders)',
        ids,
      );
      expect(rows.single['n'], 4096);
      await db.close();
    });
  });

  group('transaction', () {
    test(
      'commits, and rethrows the identical error after rolling back',
      () async {
        final db = await openWithTable('tx.db');
        final committed = await db.transaction((tx) async {
          await tx.execute('INSERT INTO t(id) VALUES (1)');
          return 'done';
        });
        expect(committed, 'done');

        final failure = _Marker();
        Object? caught;
        try {
          await db.transaction((tx) async {
            await tx.execute('INSERT INTO t(id) VALUES (2)');
            throw failure;
          });
        } catch (error) {
          caught = error;
        }
        expect(identical(caught, failure), isTrue);
        final ids = await db.select('SELECT id FROM t ORDER BY id');
        expect(ids.map((r) => r['id']), <Object?>[1]);
        await db.close();
      },
    );

    test(
      'tx.select sees uncommitted rows; db.select does not and is not blocked',
      () async {
        final db = await openWithTable('isolation.db');
        final release = Completer<void>();
        final insideSaw = Completer<int>();
        final pending = db.transaction((tx) async {
          await tx.execute('INSERT INTO t(id) VALUES (1)');
          insideSaw.complete(
            (await tx.select('SELECT COUNT(*) AS n FROM t')).single['n']!
                as int,
          );
          await release.future;
        });
        expect(await insideSaw.future, 1);
        final outside = await db
            .select('SELECT COUNT(*) AS n FROM t')
            .timeout(const Duration(seconds: 5));
        expect(outside.single['n'], 0);
        release.complete();
        await pending;
        expect((await db.select('SELECT COUNT(*) AS n FROM t')).single['n'], 1);
        await db.close();
      },
    );

    test('writes on the handle wait for a running transaction', () async {
      final db = await openWithTable('ordering.db');
      final release = Completer<void>();
      final started = Completer<void>();
      final order = <String>[];
      final tx = db.transaction((tx) async {
        started.complete();
        await release.future;
        await tx.execute('INSERT INTO t(id) VALUES (1)');
        order.add('tx');
      });
      await started.future;
      final standalone = db
          .execute('INSERT INTO t(id) VALUES (2)')
          .then((_) => order.add('standalone'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(order, isEmpty);
      release.complete();
      await Future.wait(<Future<void>>[tx, standalone]);
      expect(order, <String>['tx', 'standalone']);
      await db.close();
    });

    test('calls on the handle inside the body join the transaction', () async {
      final db = await openWithTable('zone.db');
      try {
        await db.transaction((tx) async {
          await db.execute('INSERT INTO t(id) VALUES (1)');
          expect(
            (await db.select('SELECT COUNT(*) AS n FROM t')).single['n'],
            1,
          );
          throw StateError('roll back');
        });
      } on StateError {
        // expected
      }
      expect((await db.select('SELECT COUNT(*) AS n FROM t')).single['n'], 0);
      await db.close();
    });

    test('nested transactions are savepoints', () async {
      final db = await openWithTable('nested.db');
      await db.transaction((tx) async {
        await tx.execute('INSERT INTO t(id) VALUES (1)');
        try {
          await tx.transaction((inner) async {
            await inner.execute('INSERT INTO t(id) VALUES (2)');
            throw StateError('undo inner');
          });
        } on StateError {
          // expected
        }
        await db.transaction((inner) async {
          await inner.execute('INSERT INTO t(id) VALUES (3)');
        });
      });
      final ids = await db.select('SELECT id FROM t ORDER BY id');
      expect(ids.map((r) => r['id']), <Object?>[1, 3]);
      await db.close();
    });

    test('a transaction object is dead after its body', () async {
      final db = await openWithTable('dead.db');
      late localsql.Transaction escaped;
      await db.transaction((tx) async => escaped = tx);
      expect(() => escaped.execute('SELECT 1'), throwsStateError);
      await db.close();
    });
  });

  group('busy', () {
    test(
      'a write blocked by another handle reports database is locked',
      () async {
        final path = file('busy.db');
        final a = await localsql.Database.open(path);
        await a.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        final b = await localsql.Database.open(path);
        await b.execute('PRAGMA busy_timeout = 50');
        final release = Completer<void>();
        final holding = Completer<void>();
        final hold = a.transaction((tx) async {
          await tx.execute('INSERT INTO t(id) VALUES (1)');
          holding.complete();
          await release.future;
        });
        await holding.future;
        Object? error;
        try {
          await b.execute('INSERT INTO t(id) VALUES (2)');
        } catch (e) {
          error = e;
        }
        release.complete();
        await hold;
        expect(error, isA<localsql.LocalSqliteQueryException>());
        final text = error.toString().toLowerCase();
        expect(text, contains('database is locked'));
        expect(text, contains('sqlite code: 5'));
        expect((error! as localsql.LocalSqliteException).isBusy, isTrue);
        await b.close();
        await a.close();
      },
    );
  });

  group('read-only and inline handles', () {
    test('read-only handles read committed data and refuse writes', () async {
      final path = file('ro.db');
      final writer = await openWithTable('ro.db');
      await writer.execute('INSERT INTO t(id) VALUES (1)');
      final reader = await localsql.Database.open(path, readOnly: true);
      expect((await reader.select('SELECT id FROM t')).single['id'], 1);
      await expectLater(
        reader.execute('INSERT INTO t(id) VALUES (2)'),
        throwsA(
          isA<localsql.LocalSqliteQueryException>().having(
            (e) => e.sqliteCode,
            'sqliteCode',
            8,
          ),
        ),
      );
      await writer.execute('INSERT INTO t(id) VALUES (3)');
      expect(
        (await reader.select('SELECT COUNT(*) AS n FROM t')).single['n'],
        2,
      );
      await reader.close();
      await writer.close();
    });

    test('onCurrentIsolate handles work inside a worker isolate', () async {
      final path = file('inline.db');
      final count = await Isolate.run(() async {
        final db = await localsql.Database.open(path, onCurrentIsolate: true);
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
        await db.transaction((tx) async {
          await tx.executeBatch(
            'INSERT INTO t(id, v) VALUES (?, ?)',
            <List<Object?>>[
              for (var i = 0; i < 1000; i++) <Object?>[i, 'v$i'],
            ],
          );
        });
        final n = (await db.select('SELECT COUNT(*) AS n FROM t')).single['n'];
        await db.close();
        return n;
      });
      expect(count, 1000);
      final db = await localsql.Database.open(path, readOnly: true);
      expect(
        (await db.select('SELECT v FROM t WHERE id = 999')).single['v'],
        'v999',
      );
      await db.close();
    });
  });

  group('review regressions', () {
    test('a failed writable open stops its worker isolate', () async {
      final path = file('not_a_db.db');
      File(path).writeAsStringSync('this is not sqlite ' * 400);
      final before = localsql.debugLiveLocalSqliteWorkers;
      for (var i = 0; i < 4; i++) {
        await expectLater(
          localsql.Database.open(path),
          throwsA(isA<localsql.LocalSqliteConnectionException>()),
        );
      }
      for (var i = 0; i < 100; i++) {
        if (localsql.debugLiveLocalSqliteWorkers <= before) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(localsql.debugLiveLocalSqliteWorkers, before);
    });

    test('closing writable handles stops their writer isolates', () async {
      final before = localsql.debugLiveLocalSqliteWorkers;
      final handles = <localsql.Database>[
        for (var i = 0; i < 3; i++) await openWithTable('w$i.db'),
      ];
      for (final db in handles) {
        await db.close();
      }
      for (var i = 0; i < 100; i++) {
        if (localsql.debugLiveLocalSqliteWorkers <= before) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(localsql.debugLiveLocalSqliteWorkers, before);
    });

    test('reading a WAL file leaves no -wal / -shm sidecars behind', () async {
      final path = file('store.cetg');
      final writer = await openWithTable('store.cetg');
      await writer.execute('INSERT INTO t(id) VALUES (1)');
      await writer.close();
      expect(File(path).readAsBytesSync()[18], 2, reason: 'WAL-mode file');
      expect(File('$path-wal').existsSync(), isFalse);

      final reader = await localsql.Database.open(path, readOnly: true);
      expect((await reader.select('SELECT id FROM t')).single['id'], 1);
      await reader.close();
      for (var i = 0; i < 50 && File('$path-shm').existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(File('$path-wal').existsSync(), isFalse);
      expect(File('$path-shm').existsSync(), isFalse);
    });

    test(
      'a rollback-journal file is read without creating any sidecar',
      () async {
        final path = file('delete_mode.cetg');
        final writer = await openWithTable('delete_mode.cetg');
        await writer.execute('INSERT INTO t(id) VALUES (1)');
        await writer.execute('PRAGMA journal_mode = DELETE');
        await writer.close();
        expect(File(path).readAsBytesSync()[18], 1, reason: 'rollback mode');

        final reader = await localsql.Database.open(path, readOnly: true);
        expect((await reader.select('SELECT id FROM t')).single['id'], 1);
        expect(File('$path-wal').existsSync(), isFalse);
        expect(File('$path-shm').existsSync(), isFalse);
        await reader.close();
      },
    );

    test(
      'a read-only handle still reads a file in a read-only directory',
      () async {
        final sub = Directory(p.join(dir.path, 'locked'))..createSync();
        final path = p.join(sub.path, 'ro.db');
        final writer = await localsql.Database.open(path);
        await writer.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await writer.execute('INSERT INTO t(id) VALUES (7)');
        await writer.execute('PRAGMA journal_mode = DELETE');
        await writer.close();
        await Process.run('chmod', <String>['a-w', path]);
        await Process.run('chmod', <String>['a-w', sub.path]);
        addTearDown(
          () => Process.run('chmod', <String>['-R', 'u+w', sub.path]),
        );

        final reader = await localsql.Database.open(path, readOnly: true);
        expect((await reader.select('SELECT id FROM t')).single['id'], 7);
        await reader.close();
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : false,
    );

    test(
      'closing a read-only handle does not wait behind other long reads',
      () async {
        final writer = await openWithTable('busy_pool.db');
        final quick = await localsql.Database.open(
          file('busy_pool.db'),
          readOnly: true,
        );
        expect(await quick.select('SELECT 1 AS one'), isNotEmpty);
        // Occupy every pooled reader with slow reads on another handle.
        const slow =
            'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c '
            'WHERE x < 4000000) SELECT COUNT(*) AS n FROM c';
        final slowReads = <Future<Object?>>[
          for (var i = 0; i < 6; i++) writer.select(slow),
        ];
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final sw = Stopwatch()..start();
        await quick.close();
        sw.stop();
        expect(sw.elapsedMilliseconds, lessThan(400));
        await Future.wait(slowReads);
        await writer.close();
      },
    );
  });

  group('close', () {
    test(
      'is idempotent, waits for running work, then rejects new work',
      () async {
        final db = await openWithTable('close.db');
        final insert = db.executeBatch(
          'INSERT INTO t(id) VALUES (?)',
          <List<Object?>>[
            for (var i = 0; i < 2000; i++) <Object?>[i],
          ],
        );
        final read = db.select('SELECT COUNT(*) AS n FROM t');
        final closing = Future.wait(<Future<void>>[db.close(), db.close()]);
        await insert;
        await read;
        await closing;
        expect(db.isClosed, isTrue);
        await expectLater(
          db.select('SELECT 1'),
          throwsA(
            isA<localsql.LocalSqliteConnectionException>().having(
              (e) => e.message,
              'message',
              'Database is closed.',
            ),
          ),
        );
      },
    );

    test(
      'the last close checkpoints, so the file can be renamed alone',
      () async {
        final build = file('tree.cetg.build-1');
        final published = file('tree.cetg');
        final db = await localsql.Database.open(build);
        await db.execute('CREATE TABLE g(id INTEGER PRIMARY KEY, v TEXT)');
        await db.transaction((tx) async {
          await tx.executeBatch(
            'INSERT INTO g(id, v) VALUES (?, ?)',
            <List<Object?>>[
              for (var i = 0; i < 5000; i++) <Object?>[i, 'value $i'],
            ],
          );
        });
        expect(
          (await db.select('SELECT COUNT(*) AS n FROM g')).single['n'],
          5000,
        );
        await db.close();
        expect(File('$build-wal').existsSync(), isFalse);
        expect(File('$build-shm').existsSync(), isFalse);

        File(build).renameSync(published);
        final reopened = await localsql.Database.open(
          published,
          readOnly: true,
        );
        expect(
          (await reopened.select('SELECT COUNT(*) AS n FROM g')).single['n'],
          5000,
        );
        await reopened.close();
      },
    );
  });

  test('reads run concurrently across the reader pool', () async {
    final db = await openWithTable('pool.db');
    await db.executeBatch(
      'INSERT INTO t(id, name) VALUES (?, ?)',
      <List<Object?>>[
        for (var i = 0; i < 20000; i++) <Object?>[i, 'name $i'],
      ],
    );
    final results = await Future.wait(<Future<List<Map<String, Object?>>>>[
      for (var i = 0; i < 12; i++)
        db.select(
          'SELECT COUNT(*) AS n, SUM(id) AS s FROM t WHERE id % ? = 0',
          <Object?>[i + 1],
        ),
    ]);
    for (var i = 0; i < results.length; i++) {
      final step = i + 1;
      expect(results[i].single['n'], (19999 ~/ step) + 1);
    }
    await db.close();
  });
}

final class _Marker implements Exception {}
