@TestOn('browser')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/web/shims/local_sqlite.dart';

import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);

  test('opens a database in the browser file system', () async {
    final dir = await Directory.systemTemp.createTemp('smoke');
    final db = await Database.open('${dir.path}/a.db');
    await db.execute('PRAGMA journal_mode=WAL');
    await db.execute('CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT)');
    await db.executeBatch('INSERT INTO t(b) VALUES (?)', [
      for (var i = 0; i < 1000; i++) ['row $i'],
    ]);
    final rows = await db.select('SELECT COUNT(*) AS n FROM t');
    expect(rows.single['n'], 1000);
    final mode = await db.select('PRAGMA journal_mode');
    // ignore: avoid_print
    print('journal mode: $mode');
    await db.close();
  });
}
