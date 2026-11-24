@TestOn('browser')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:web/web.dart' as web;

import 'package:chessever/desktop/services/compact_local_tree_index.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/web/shims/local_sqlite_web.dart';

import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);

  setUp(() {
    final document = web.document;
    final base = document.createElement('base') as web.HTMLBaseElement;
    final originalUrl = web.window.location.href;
    final originalState = web.window.history.state;
    final originalWasmUrl = debugLocalSqliteWasmUrl;

    // The Wasm fixture is served separately from the browser test runner.
    // Give it the same role as the app's <base href> on the player route.
    base.href = 'http://127.0.0.1:8377/';
    document.head!.prepend(base);
    final playerUrl = Uri.parse(
      originalUrl,
    ).resolve('/player/andrey-esipenko/24175439/games');
    web.window.history.replaceState(null, '', playerUrl.toString());
    debugLocalSqliteWasmUrl = null;
    addTearDown(() {
      debugLocalSqliteWasmUrl = originalWasmUrl;
      base.remove();
      web.window.history.replaceState(originalState, '', originalUrl);
    });
  });

  test('builds and reads a local tree after opening a player link', () async {
    final root = await Directory.systemTemp.createTemp('player-tree-');
    addTearDown(() => root.delete(recursive: true));
    final pgn = File(
      '${root.path}/CHESSEVER_24175439_CHESSEVER_ANDREY_ESIPENKO.pgn',
    );
    await pgn.writeAsString('''
[Event "Test"]
[White "Andrey Esipenko"]
[Black "Test Player"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''');

    final repository = LocalChessDatabaseRepository(
      database: () => LocalChessCacheDatabase.instance.database,
    );
    final tree = await repository.rebuildOpeningTreeFromPgnFile(
      databasePath: pgn.path,
    );
    expect(tree!.index.isUsable, isTrue);
    expect(
      await File(compactLocalTreeGameIndexPath(pgn.path)).exists(),
      isTrue,
    );

    const initialFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final moves = await repository.localMoveAggregatesForFen(
      databasePath: pgn.path,
      fen: initialFen,
    );
    expect(moves.single.uci, 'e2e4');
    final games = await repository.localPositionGamesResponse(
      databasePath: pgn.path,
      fen: initialFen,
      sortBy: GamebaseSortField.date,
      sortDirection: GamebaseSortDirection.desc,
      pageNumber: 0,
      pageSize: 50,
    );
    expect(games!.data, hasLength(1));
  });

  test(
    'the app database can save settings without a worker on a deep link',
    () async {
      final factory = createDatabaseFactoryFfiWeb(
        noWebWorker: true,
        options: SqfliteFfiWebOptions(sqlite3WasmUri: webSqliteWasmUri),
      );
      final db = await factory.openDatabase(':memory:');
      addTearDown(db.close);

      await db.execute('CREATE TABLE settings (board_theme TEXT)');
      await db.insert('settings', {'board_theme': 'green'});
      expect(await db.query('settings'), [
        {'board_theme': 'green'},
      ]);
    },
  );
}
