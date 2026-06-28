import 'dart:io';

import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_append.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';

void main() {
  group('appendableLocalPgnParts', () {
    test('keeps multi-PGN games with moves and skips header-only text', () {
      const first = '''
[Event "TWIC"]
[Date "2026.06.04"]
[White "White One"]
[Black "Black One"]
[Result "1-0"]

1. e4 e5 1-0
''';
      const headerOnly = '''
[Event "No moves"]
[White "White Two"]
[Black "Black Two"]
[Result "*"]

*
''';
      const second = '''
[Event "TWIC"]
[Date "2026.06.04"]
[White "White Three"]
[Black "Black Three"]
[Result "0-1"]

1. d4 Nf6 0-1
''';

      final parts = appendableLocalPgnParts('$first\n\n$headerOnly\n\n$second');

      expect(parts, [first.trim(), second.trim()]);
    });
  });

  group('appendPgnTextToLocalChessFile', () {
    test(
      'appends valid clipboard PGNs into an existing PGN database',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-paste-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/local.pgn');
        await file.writeAsString(
          '''
[Event "Existing"]
[White "A"]
[Black "B"]
[Result "1/2-1/2"]

1. c4 c5 1/2-1/2
'''.trim(),
        );

        const pasted = '''
[Event "TWIC"]
[White "Grining, Maria"]
[Black "Dietrich, Anja"]
[Result "1-0"]

1. e4 e5 1-0
''';

        final count = await appendPgnTextToLocalChessFile(
          filePath: file.path,
          text: pasted,
        );

        expect(count, 1);
        final contents = await file.readAsString();
        expect(contents, contains('[Event "Existing"]'));
        expect(contents, contains('[Black "Dietrich, Anja"]'));
        expect(contents, contains('1. e4 e5 1-0'));
      },
    );

    test('skips duplicate PGNs using loaded database fingerprints', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-local-paste-dedupe-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/local.pgn');
      const existing = '''
[Event "Existing"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 e5 1-0
''';
      const duplicateWithWhitespace = '''
[Event "Existing"]
[White "A"]
[Black "B"]
[Result "1-0"]

1.   e4    e5    1-0
''';
      const fresh = '''
[Event "Fresh"]
[White "C"]
[Black "D"]
[Result "0-1"]

1. d4 Nf6 0-1
''';
      await file.writeAsString(existing.trim());

      final count = await appendPgnTextToLocalChessFile(
        filePath: file.path,
        text: '$duplicateWithWhitespace\n\n$fresh',
        existingFingerprints: {localChessPgnFingerprint(existing)},
      );

      expect(count, 1);
      final contents = await file.readAsString();
      expect(
        RegExp(r'\[Event "Existing"\]').allMatches(contents),
        hasLength(1),
      );
      expect(contents, contains('[Event "Fresh"]'));
    });

    test(
      'skips duplicate PGNs with comments reordered headers and SAN suffix variants',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-paste-san-dedupe-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/local.pgn');
        const existing = '''
[Event "Castling"]
[Site "Local"]
[Date "2026.06.28"]
[Round "1"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. 0-0 Nf6 5. Re1+ 1-0
''';
        const duplicate = '''
[Black "B"]
[White "A"]
[Round "1"]
[Date "2026.06.28"]
[Site "Local"]
[Event "Castling"]
[Result "1-0"]

1. e4 {main line} e5 2. Nf3 (2. Bc4) Nc6 3. Bc4 Bc5 4. O-O Nf6
5. Re1 1-0
''';
        const fresh = '''
[Event "Fresh"]
[White "C"]
[Black "D"]
[Result "0-1"]

1. d4 Nf6 0-1
''';
        await file.writeAsString(existing.trim());

        final count = await appendPgnTextToLocalChessFile(
          filePath: file.path,
          text: '$duplicate\n\n$fresh',
          existingFingerprints: {localChessPgnFingerprint(existing)},
        );

        expect(count, 1);
        final contents = await file.readAsString();
        expect(
          RegExp(r'\[Event "Castling"\]').allMatches(contents),
          hasLength(1),
        );
        expect(contents, contains('[Event "Fresh"]'));
      },
    );

    test(
      'skips duplicate PGNs using resqlite fingerprints beyond loaded preview',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-paste-db-dedupe-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/local.pgn');
        await file.writeAsString(
          '${_existingPgn.trim()}\n\n${_secondPgn.trim()}\n',
        );
        final db = await resqlite.Database.open('${dir.path}/local_chess.db');
        addTearDown(db.close);
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        final source = await scanLocalChessPaths(<String>[file.path]);
        final fileNode = source.root.singlePlayableDatabaseInSubtree!;
        final writeRepo = LocalChessDatabaseRepository(
          database: () async => db,
        );
        await writeRepo.persistFileNode(fileNode, sourceLabel: source.label);
        final readRepo = LocalChessDatabaseRepository(
          database: () async => db,
          cachedFileNodeGamePreviewLimit: 1,
        );
        final preview = await readRepo.loadFreshFileNode(
          file.path,
          rootPath: dir.path,
        );
        expect(preview, isNotNull);
        expect(preview!.games, hasLength(1));
        expect(preview.gameCount, 2);

        final count = await appendPgnTextToLocalChessDatabaseFile(
          repository: readRepo,
          filePath: file.path,
          text: _secondPgnWithExtraWhitespace,
          fallbackFingerprints: {
            for (final game in preview.games) game.pgnFingerprint,
          },
        );

        expect(count, 0);
        final contents = await file.readAsString();
        expect(
          RegExp(r'\[Event "Second"\]').allMatches(contents),
          hasLength(1),
        );
      },
    );

    test(
      'queries only pasted candidate fingerprints for cached dedupe',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-paste-candidate-dedupe-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/local.pgn');
        await file.writeAsString(
          '${_existingPgn.trim()}\n\n${_secondPgn.trim()}\n',
        );
        final repo = _CandidateFingerprintRepository(
          existingFingerprints: {localChessPgnFingerprint(_secondPgn)},
        );

        final count = await appendPgnTextToLocalChessDatabaseFile(
          repository: repo,
          filePath: file.path,
          text: '$_secondPgnWithExtraWhitespace\n\n$_thirdPgn',
          fallbackFingerprints: {localChessPgnFingerprint(_existingPgn)},
        );

        expect(count, 1);
        expect(repo.allFingerprintCalls, 0);
        expect(
          repo.queriedFingerprints,
          containsAll(<String>{
            localChessPgnFingerprint(_secondPgn),
            localChessPgnFingerprint(_thirdPgn),
          }),
        );
        expect(repo.persistedAppends, hasLength(1));
        expect(
          repo.persistedAppends.single.rawPgn,
          contains('[Event "Third"]'),
        );
        final contents = await file.readAsString();
        expect(
          RegExp(r'\[Event "Second"\]').allMatches(contents),
          hasLength(1),
        );
        expect(contents, contains('[Event "Third"]'));
      },
    );

    test(
      'incrementally persists appended PGNs into the resqlite cache',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-paste-db-append-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/local.pgn');
        await file.writeAsString('${_existingPgn.trim()}\n');
        final db = await resqlite.Database.open('${dir.path}/local_chess.db');
        addTearDown(db.close);
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        final source = await scanLocalChessPaths(<String>[file.path]);
        final fileNode = source.root.singlePlayableDatabaseInSubtree!;
        final repo = LocalChessDatabaseRepository(database: () async => db);
        await repo.persistFileNode(fileNode, sourceLabel: source.label);

        final count = await appendPgnTextToLocalChessDatabaseFile(
          repository: repo,
          filePath: file.path,
          text: _secondPgn,
          fallbackFingerprints: {
            for (final game in fileNode.games) game.pgnFingerprint,
          },
        );

        expect(count, 1);
        final gameCountRows = await db.select(
          'SELECT COUNT(*) AS count FROM local_chess_games',
        );
        expect(gameCountRows.single['count'], 2);
        final restored = await repo.loadFreshFileNode(
          file.path,
          rootPath: dir.path,
        );
        expect(restored, isNotNull);
        expect(restored!.gameCount, 2);
        expect(
          restored.games.map((game) => game.game.metadata['Event']),
          contains('Second'),
        );
        final moves = await repo.localMoveAggregatesForFen(
          databasePath: file.path,
          fen: Chess.initial.fen,
        );
        expect(
          moves.map((move) => move.uci),
          containsAll(<String>['e2e4', 'd2d4']),
        );
        final d4 = moves.singleWhere((move) => move.uci == 'd2d4');
        expect(d4.black, 1);
        expect(d4.total, 1);
      },
    );
  });
  group('removeLocalPgnGamesFromFile', () {
    test('rewrites a PGN database without the selected game indexes', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-local-delete-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/local.pgn');
      const first = '''
[Event "Keep one"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 e5 1-0
''';
      const second = '''
[Event "Delete me"]
[White "C"]
[Black "D"]
[Result "0-1"]

1. d4 Nf6 0-1
''';
      const third = '''
[Event "Keep two"]
[White "E"]
[Black "F"]
[Result "1/2-1/2"]

1. c4 c5 1/2-1/2
''';
      await file.writeAsString(
        '${first.trim()}\n\n${second.trim()}\n\n${third.trim()}\n',
      );

      final removed = await removeLocalPgnGamesFromFile(
        filePath: file.path,
        indexesInFile: {1},
      );

      expect(removed, 1);
      final contents = await file.readAsString();
      expect(contents, contains('[Event "Keep one"]'));
      expect(contents, isNot(contains('[Event "Delete me"]')));
      expect(contents, contains('[Event "Keep two"]'));
    });

    test('removes cached games from file and resqlite tree', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-local-delete-db-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/local.pgn');
      await file.writeAsString(
        '${_existingPgn.trim()}\n\n${_secondPgn.trim()}\n',
      );
      final db = await resqlite.Database.open('${dir.path}/local_chess.db');
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      await createLocalChessResqliteDatabaseSchema(db);
      final source = await scanLocalChessPaths(<String>[file.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final removed = await removeLocalPgnGamesFromDatabaseFile(
        repository: repo,
        filePath: file.path,
        indexesInFile: {1},
      );

      expect(removed, 1);
      final contents = await file.readAsString();
      expect(contents, contains('[Event "Existing"]'));
      expect(contents, isNot(contains('[Event "Second"]')));
      final gameCountRows = await db.select(
        'SELECT COUNT(*) AS count FROM local_chess_games',
      );
      expect(gameCountRows.single['count'], 1);
      final restored = await repo.loadFreshFileNode(
        file.path,
        rootPath: dir.path,
      );
      expect(restored, isNotNull);
      expect(restored!.gameCount, 1);
      expect(restored.games.single.game.metadata['Event'], 'Existing');
      final moves = await repo.localMoveAggregatesForFen(
        databasePath: file.path,
        fen: Chess.initial.fen,
      );
      expect(moves.map((move) => move.uci), ['e2e4']);
    });

    test('reindexes kept cached games after deleting from the front', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-local-delete-reindex-db-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/local.pgn');
      await file.writeAsString(
        '${_existingPgn.trim()}\n\n${_secondPgn.trim()}\n',
      );
      final db = await resqlite.Database.open('${dir.path}/local_chess.db');
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      await createLocalChessResqliteDatabaseSchema(db);
      final source = await scanLocalChessPaths(<String>[file.path]);
      final fileNode = source.root.singlePlayableDatabaseInSubtree!;
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(fileNode, sourceLabel: source.label);

      final removed = await removeLocalPgnGamesFromDatabaseFile(
        repository: repo,
        filePath: file.path,
        indexesInFile: {0},
      );

      expect(removed, 1);
      final rows = await db.select('''
        SELECT index_in_file, file_game_count
        FROM local_chess_games
        ORDER BY index_in_file ASC
        ''');
      expect(rows, hasLength(1));
      expect(rows.single['index_in_file'], 0);
      expect(rows.single['file_game_count'], 1);
      final restored = await repo.loadFreshFileNode(
        file.path,
        rootPath: dir.path,
      );
      expect(restored, isNotNull);
      expect(restored!.games.single.indexInFile, 0);
      expect(restored.games.single.game.metadata['Event'], 'Second');
    });

    test(
      'replaces cached game in file, metadata rows, and resqlite tree',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-replace-db-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/local.pgn');
        await file.writeAsString(
          '${_existingPgn.trim()}\n\n${_secondPgn.trim()}\n',
        );
        final db = await resqlite.Database.open('${dir.path}/local_chess.db');
        addTearDown(db.close);
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        final source = await scanLocalChessPaths(<String>[file.path]);
        final fileNode = source.root.singlePlayableDatabaseInSubtree!;
        final repo = LocalChessDatabaseRepository(database: () async => db);
        await repo.persistFileNode(fileNode, sourceLabel: source.label);

        final replaced = await repo.replaceLocalPgnGame(
          databasePath: file.path,
          indexInFile: 1,
          rawPgn: _replacementPgn,
        );

        expect(replaced, isTrue);
        final contents = await file.readAsString();
        expect(contents, contains('[Event "Replacement"]'));
        expect(contents, contains('1. Nf3 Nf6'));
        expect(contents, isNot(contains('[Event "Second"]')));
        expect(contents, isNot(contains('1. d4 Nf6')));
        final eventRows = await db.select('''
        SELECT headers_json, index_in_file, file_game_count
        FROM local_chess_games
        ORDER BY index_in_file ASC
        ''');
        expect(eventRows, hasLength(2));
        expect(eventRows.last['headers_json'], contains('Replacement'));
        expect(eventRows.last['index_in_file'], 1);
        expect(eventRows.last['file_game_count'], 2);
        final restored = await repo.loadFreshFileNode(
          file.path,
          rootPath: dir.path,
        );
        expect(restored, isNotNull);
        expect(restored!.gameCount, 2);
        expect(restored.games.last.game.metadata['Event'], 'Replacement');
        final moves = await repo.localMoveAggregatesForFen(
          databasePath: file.path,
          fen: Chess.initial.fen,
        );
        expect(moves.map((move) => move.uci), containsAll(['e2e4', 'g1f3']));
        expect(moves.map((move) => move.uci), isNot(contains('d2d4')));
      },
    );
  });
}

const _existingPgn = '''
[Event "Existing"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 e5 1-0
''';

const _secondPgn = '''
[Event "Second"]
[White "C"]
[Black "D"]
[Result "0-1"]

1. d4 Nf6 0-1
''';

const _secondPgnWithExtraWhitespace = '''
[Event "Second"]
[White "C"]
[Black "D"]
[Result "0-1"]

1.   d4     Nf6      0-1
''';

const _thirdPgn = '''
[Event "Third"]
[White "E"]
[Black "F"]
[Result "1/2-1/2"]

1. c4 c5 1/2-1/2
''';

const _replacementPgn = '''
[Event "Replacement"]
[White "C"]
[Black "D"]
[Result "1-0"]

1. Nf3 Nf6 1-0
''';

class _CandidateFingerprintRepository extends LocalChessDatabaseRepository {
  _CandidateFingerprintRepository({required this.existingFingerprints})
    : super(database: _unusedDatabase);

  final Set<String> existingFingerprints;
  final Set<String> queriedFingerprints = <String>{};
  final List<LocalChessAppendedPgn> persistedAppends =
      <LocalChessAppendedPgn>[];
  int allFingerprintCalls = 0;

  @override
  Future<Set<String>?> localDatabasePgnFingerprints({
    required String databasePath,
  }) async {
    allFingerprintCalls++;
    throw StateError('append dedupe should not load every stored hash');
  }

  @override
  Future<Set<String>?> localDatabaseMatchingPgnFingerprints({
    required String databasePath,
    required Iterable<String> fingerprints,
  }) async {
    queriedFingerprints.addAll(fingerprints);
    return existingFingerprints.intersection(queriedFingerprints);
  }

  @override
  Future<bool> persistAppendedPgnGames({
    required String databasePath,
    required List<LocalChessAppendedPgn> appendedPgns,
  }) async {
    persistedAppends.addAll(appendedPgns);
    return true;
  }
}

Future<resqlite.Database> _unusedDatabase() async {
  throw StateError('test repository does not open a database');
}
