import 'dart:io';

import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

void main() {
  late Database db;
  late Directory temp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('PRAGMA foreign_keys=ON');
    await createLocalChessDatabaseSchema(db);
    temp = await Directory.systemTemp.createTemp('chessever-local-db-');
  });

  tearDown(() async {
    await db.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('persists imported PGN games and opening tree in SQLite rows', () async {
    final pgnFile = File('${temp.path}/mini.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);

    await repo.persistFileNode(fileNode, sourceLabel: source.label);

    expect(await _count(db, 'local_chess_databases'), 1);
    expect(await _count(db, 'local_chess_games'), 2);
    expect(await _count(db, 'local_chess_players'), greaterThanOrEqualTo(5));
    expect(await _count(db, 'local_chess_events'), greaterThanOrEqualTo(2));
    expect(await _count(db, 'local_chess_sites'), greaterThanOrEqualTo(2));
    expect(await _count(db, 'local_chess_tree_nodes'), greaterThan(1));
    expect(await _count(db, 'local_chess_tree_moves'), greaterThan(1));
    expect(await _count(db, 'local_chess_position_games'), greaterThan(1));

    final restored = await repo.loadFreshFileNode(
      pgnFile.path,
      rootPath: temp.path,
    );

    expect(restored, isNotNull);
    expect(restored!.games, hasLength(2));
    expect(restored.openingTreeIndex, isNotNull);
    expect(restored.openingTreeIndex!.downloadedGameCount, 2);
    expect(
      restored.openingTreeIndex!.movesForFen(Chess.initial.fen),
      isNotEmpty,
    );
    expect(restored.games.first.rawPgn, contains('[Event "Fast tree"]'));
  });

  test(
    'rejects stale persisted PGN rows when the file fingerprint changes',
    () async {
      final pgnFile = File('${temp.path}/stale.pgn');
      await pgnFile.writeAsString(_samplePgn);
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await pgnFile.writeAsString('[Event "Changed"]\n\n1. c4 c5 *\n');

      final restored = await repo.loadFreshFileNode(
        pgnFile.path,
        rootPath: temp.path,
      );

      expect(restored, isNull);
    },
  );
  test('returns null for an uncached single source', () async {
    final pgnFile = File('${temp.path}/uncached.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final repo = LocalChessDatabaseRepository(database: () async => db);

    final restored = await repo.loadFreshSource(<String>[pgnFile.path]);

    expect(restored, isNull);
  });

  test('cached folder source skips empty non-chess subdirectories', () async {
    final root = Directory('${temp.path}/workspace');
    await root.create();
    final docs = Directory('${root.path}/docs');
    await docs.create();
    await File('${docs.path}/notes.txt').writeAsString('not chess');
    final pgnFile = File('${root.path}/lines.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[root.path]);
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistSource(source);

    final restored = await repo.loadFreshSource(<String>[root.path]);

    expect(restored, isNotNull);
    expect(restored!.root.gameCount, 2);
    expect(restored.root.folders, isEmpty);
    expect(restored.root.files.single.path, pgnFile.path);
  });

  test('rejects cached PGN rows when opening tree nodes are missing', () async {
    final pgnFile = File('${temp.path}/corrupt-cache.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);
    await db.delete('local_chess_tree_nodes');

    final restored = await repo.loadFreshFileNode(
      pgnFile.path,
      rootPath: temp.path,
    );

    expect(restored, isNull);
  });

  test('persists local-only board annotations by game id', () async {
    final pgnFile = File('${temp.path}/annotated.pgn');
    await pgnFile.writeAsString(_samplePgn);
    final source = await scanLocalChessPaths(<String>[pgnFile.path]);
    final fileNode = source.root.singlePlayableDatabaseInSubtree!;
    final repo = LocalChessDatabaseRepository(database: () async => db);
    await repo.persistFileNode(fileNode, sourceLabel: source.label);
    final databaseRow =
        (await db.query('local_chess_databases', limit: 1)).single;
    final now = DateTime.utc(2026, 6, 26);

    await repo.saveLocalGameAnalysis(
      LocalChessGameAnalysis(
        gameId: fileNode.games.first.id,
        databaseId: databaseRow['id'] as String,
        analysisState: const <String, dynamic>{'pane': 'tree'},
        variationComments: const <String, String>{'0:0': 'critical'},
        moveNags: const <String, List<int>>{
          '0:0': <int>[1, 14],
        },
        lastViewedPosition: 3,
        notes: 'Remember this line',
        isFavorite: true,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final restored = await repo.localGameAnalysis(fileNode.games.first.id);

    expect(restored, isNotNull);
    expect(restored!.analysisState, {'pane': 'tree'});
    expect(restored.variationComments, {'0:0': 'critical'});
    expect(restored.moveNags, {
      '0:0': <int>[1, 14],
    });
    expect(restored.lastViewedPosition, 3);
    expect(restored.notes, 'Remember this line');
    expect(restored.isFavorite, isTrue);
  });
}

Future<int> _count(Database db, String table) async {
  return Sqflite.firstIntValue(
    await db.rawQuery('SELECT COUNT(*) FROM $table'),
  )!;
}

const _samplePgn = '''
[Event "Fast tree"]
[Site "Local"]
[Date "2024.01.03"]
[Round "1"]
[White "Hou, Yifan"]
[Black "Gukesh, D"]
[WhiteElo "2650"]
[BlackElo "2760"]
[ECO "D06"]
[Result "1/2-1/2"]

1. d4 d5 2. c4 e5 3. Nf3 Nc6 1/2-1/2

[Event "Training"]
[Site "Budapest"]
[Date "2024.05.05"]
[Round "2"]
[White "Polgar, Judit"]
[Black "Anand, Viswanathan"]
[WhiteElo "2675"]
[BlackElo "2750"]
[ECO "B90"]
[Result "0-1"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 0-1
''';
