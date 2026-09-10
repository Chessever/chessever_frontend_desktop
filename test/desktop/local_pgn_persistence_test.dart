import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_append.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

String _game(int n, {String annotation = ''}) =>
    '[Event "Fixture $n"]\n[White "White $n"]\n[Black "Black $n"]\n'
    '[Site "?"]\n[Date "????.??.??"]\n[Round "?"]\n'
    '[Result "*"]\n\n1. e4 $annotation e5 2. Nf3 Nc6 *';

void main() {
  late Directory dir;
  late File file;
  late resqlite.Database db;
  late LocalChessDatabaseRepository repo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local-pgn-persistence-');
    file = File('${dir.path}/fixture.pgn');
    db = await resqlite.Database.open('${dir.path}/cache.db');
    await db.execute('PRAGMA foreign_keys=ON');
    await createLocalChessResqliteDatabaseSchema(db);
    repo = LocalChessDatabaseRepository(database: () async => db);
  });
  tearDown(() async {
    await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> import(String text) async {
    await file.writeAsString(text);
    await repo.importSingleFileSource(path: file.path);
  }

  test(
    '131 physical records / 130 cached rows survive consecutive updates',
    () async {
      final records = List.generate(130, _game)..insert(65, _game(0));
      await import('${records.join('\n\n')}\n');
      expect(
        await db.select('SELECT id FROM local_chess_games'),
        hasLength(130),
      );
      final before = await file.readAsString();
      var target = LocalLibraryGameUpdateTarget(
        sourcePath: file.path,
        indexInFile: 20,
        fileGameCount: 131,
        pgnFingerprint: localChessPgnFingerprint(records[20]),
        recordRevision: localPgnRecordRevision(records[20]),
      );
      for (final annotation in [
        '{a much longer annotation ♞}',
        '{short} (1. d4 d5)',
      ]) {
        final outcome = await updateLocalLibraryPgnGame(
          target: target,
          game: ChessGame.fromPgn('updated', _game(20, annotation: annotation)),
          repository: repo,
        );
        expect(outcome.cacheRefreshWarning, isNull);
        target = outcome.updateTarget;
        final text = await file.readAsString();
        final oldRanges = pgnGameRanges(before);
        final ranges = pgnGameRanges(text);
        expect(ranges, hasLength(131));
        for (var i = 0; i < ranges.length; i++) {
          if (i == 20) continue;
          expect(
            text.substring(ranges[i].start, ranges[i].end),
            before.substring(oldRanges[i].start, oldRanges[i].end),
          );
        }
        final rows = await db.select('SELECT * FROM local_chess_games');
        expect(rows, hasLength(130));
        final bytes = utf8.encode(text);
        for (final row in rows) {
          final index = row['index_in_file'] as int;
          final slice =
              utf8
                  .decode(
                    bytes.sublist(
                      row['source_byte_start'] as int,
                      row['source_byte_end'] as int,
                    ),
                  )
                  .trim();
          expect(
            slice,
            text.substring(ranges[index].start, ranges[index].end).trim(),
          );
          expect(row['file_game_count'], 131);
        }
      }
    },
  );

  test(
    'stale neighboring byte spans hydrate full physical mainline or fail explicitly',
    () async {
      await import('${_game(0)}\n\n${_game(1)}\n');
      final node = await repo.loadFreshFileNode(file.path, rootPath: dir.path);
      final neighbor = node!.games.last;
      final stale = LocalChessGame(
        id: neighbor.id,
        game: neighbor.game,
        rawPgn: '',
        sourcePath: neighbor.sourcePath,
        sourceRelativePath: neighbor.sourceRelativePath,
        fileName: neighbor.fileName,
        indexInFile: neighbor.indexInFile,
        fileGameCount: neighbor.fileGameCount,
        hasMoves: true,
        pgnFingerprint: neighbor.pgnFingerprint,
        sourceByteStart: neighbor.sourceByteStart,
        sourceByteEnd: neighbor.sourceByteEnd,
      );
      expect(
        await repo.replaceLocalPgnGame(
          databasePath: file.path,
          indexInFile: 0,
          expectedFileGameCount: 2,
          expectedPgnFingerprint: localChessPgnFingerprint(_game(0)),
          expectedRecordRevision: localPgnRecordRevision(_game(0)),
          rawPgn: _game(
            0,
            annotation: '{${List.filled(500, 'annotation').join(' ')}}',
          ),
        ),
        isTrue,
      );
      expect(stale.rawPgn, _game(1));
      await file.writeAsString('${_game(1)}\n\n${_game(0)}\n');
      expect(() => stale.rawPgn, throwsStateError);
    },
  );

  test(
    'different cached updates and append share one source lifetime',
    () async {
      await import('${_game(0)}\n\n${_game(1)}\n');
      final held = Completer<void>();
      final entered = Completer<void>();
      final blocker = repo.runLocalPgnWriteQueued(() async {
        entered.complete();
        await held.future;
      });
      await entered.future;
      final first = repo.replaceLocalPgnGame(
        databasePath: file.path,
        indexInFile: 0,
        rawPgn: _game(10),
        expectedFileGameCount: 2,
        expectedPgnFingerprint: localChessPgnFingerprint(_game(0)),
        expectedRecordRevision: localPgnRecordRevision(_game(0)),
      );
      final second = repo.replaceLocalPgnGame(
        databasePath: file.path,
        indexInFile: 1,
        rawPgn: _game(11),
        expectedFileGameCount: 2,
        expectedPgnFingerprint: localChessPgnFingerprint(_game(1)),
        expectedRecordRevision: localPgnRecordRevision(_game(1)),
      );
      // Let both replacements register in the FIFO before the append; each
      // replacement still sees the original count and matching revision.
      await Future<void>.delayed(Duration.zero);
      final append = appendPgnTextToLocalChessDatabaseFile(
        repository: repo,
        filePath: file.path,
        text: _game(12),
      );
      held.complete();
      await blocker;
      expect(
        await Future.wait([first, second]).timeout(const Duration(seconds: 30)),
        [true, true],
      );
      expect(await append, 1);
      final text = await file.readAsString();
      expect(pgnGameRanges(text), hasLength(3));
      expect(text, contains('Fixture 10'));
      expect(text, contains('Fixture 11'));
      expect(text, contains('Fixture 12'));
      expect(
        (await repo.loadFreshFileNode(
          file.path,
          rootPath: dir.path,
        ))!.gameCount,
        3,
      );
    },
  );

  test('malformed replacement does not overwrite a playable record', () async {
    await import('${_game(0)}\n');
    final before = await file.readAsString();
    // Rejected as unindexable, not reported as a source conflict: telling the
    // user to refresh would never make this PGN saveable.
    await expectLater(
      repo.replaceLocalPgnGame(
        databasePath: file.path,
        indexInFile: 0,
        rawPgn: '[Event "Broken"]\n\n1. NotAMove *',
        expectedRecordRevision: localPgnRecordRevision(_game(0)),
      ),
      throwsA(
        isA<LocalChessPgnReplacementRejectedException>().having(
          (error) => error.toString(),
          'message',
          allOf(contains('could not be indexed'), contains('left unchanged')),
        ),
      ),
    );
    expect(await file.readAsString(), before);
  });

  test('file-only fallback waits for the shared cache writer queue', () async {
    await file.writeAsString('${_game(0)}\n');
    final entered = Completer<void>();
    final release = Completer<void>();
    final blocker = repo.runLocalPgnWriteQueued(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    var completed = false;
    final update = updateLocalLibraryPgnGame(
      target: LocalLibraryGameUpdateTarget(
        sourcePath: file.path,
        indexInFile: 0,
        fileGameCount: 1,
        pgnFingerprint: localChessPgnFingerprint(_game(0)),
        recordRevision: localPgnRecordRevision(_game(0)),
      ),
      game: ChessGame.fromPgn('fallback', _game(10)),
    ).then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    release.complete();
    await blocker;
    await update.timeout(const Duration(seconds: 10));
    expect(await file.readAsString(), contains('Fixture 10'));
  });

  test(
    'physical replacement preserves BOM, CRLF, duplicates and fake comment headers',
    () {
      final first = _game(0, annotation: '{comment\n[Event "not a record"]\n}');
      final text =
          '\uFEFF${first.replaceAll('\n', '\r\n')}\r\n\r\n${_game(1)}\n\n${_game(1)}\n';
      final ranges = pgnGameRanges(text);
      expect(ranges, hasLength(3));
      final next = replaceLocalPgnRecordInSnapshot(
        text: text,
        indexInFile: 1,
        rawPgn: _game(2),
        expectedFileGameCount: 3,
      );
      expect(
        next.substring(0, ranges[1].start),
        text.substring(0, ranges[1].start),
      );
      expect(next, endsWith('${_game(1)}\n'));
    },
  );
  for (final useCache in [false, true]) {
    for (final change in ['{comment}', r'$1', '(1. d4 d5)']) {
      test('stale annotation revision rejects ($useCache / $change)', () async {
        final original = _game(0);
        await import(original);
        final target = LocalLibraryGameUpdateTarget(
          sourcePath: file.path,
          indexInFile: 0,
          fileGameCount: 1,
          pgnFingerprint: localChessPgnFingerprint(original),
          recordRevision: localPgnRecordRevision(original),
        );
        final changed = _game(0, annotation: change);
        // Annotation edits intentionally keep the dedupe identity unchanged.
        expect(localChessPgnFingerprint(changed), target.pgnFingerprint);
        await file.writeAsString(changed);
        await expectLater(
          updateLocalLibraryPgnGame(
            target: target,
            game: ChessGame.fromPgn('stale', _game(0, annotation: '{mine}')),
            repository: useCache ? repo : null,
          ),
          throwsStateError,
        );
        expect(await file.readAsString(), changed);
      });
    }
  }

  test(
    'deletion preserves uncached physical duplicate and reindexes all rows',
    () async {
      final records = [_game(0), _game(1), _game(0), _game(2)];
      final before = records.join('\n\n');
      await import(before);
      expect(await db.select('SELECT id FROM local_chess_games'), hasLength(3));
      expect(
        await repo.removeLocalPgnGames(
          databasePath: file.path,
          indexesInFile: {1},
          expectedFileGameCount: 4,
          expectedRecordRevisions: {1: localPgnRecordRevision(records[1])},
        ),
        1,
      );
      final after = await file.readAsString();
      final ranges = pgnGameRanges(before);
      expect(after, before.replaceRange(ranges[1].start, ranges[1].end, ''));
      expect(pgnGameRanges(after), hasLength(3));
      final rows = await db.select(
        'SELECT * FROM local_chess_games ORDER BY index_in_file',
      );
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['index_in_file']), [0, 2]);
      expect(rows.every((r) => r['file_game_count'] == 3), isTrue);
    },
  );

  test('stale deletion preserves annotation-only external edits', () async {
    await import(_game(0));
    final revision = localPgnRecordRevision(_game(0));
    final changed = _game(0, annotation: '{external}');
    await file.writeAsString(changed);
    await expectLater(
      repo.removeLocalPgnGames(
        databasePath: file.path,
        indexesInFile: {0},
        expectedRecordRevisions: {0: revision},
      ),
      throwsStateError,
    );
    expect(await file.readAsString(), changed);
  });

  test(
    'CR-only headerless and mixed records share scan/hydrate/mutation ordinals',
    () async {
      final text =
          '\uFEFF1. d4 d5 *\r\r${_game(0).replaceAll('\n', '\r')}\r\r${_game(1)}\n';
      await import(text);
      final ranges = pgnGameRanges(text);
      expect(ranges, hasLength(3));
      final rows = await db.select(
        'SELECT * FROM local_chess_games ORDER BY index_in_file',
      );
      expect(rows, hasLength(3));
      for (final row in rows) {
        final index = row['index_in_file'] as int;
        final bytes = utf8.encode(text);
        expect(
          utf8
              .decode(
                bytes.sublist(
                  row['source_byte_start'] as int,
                  row['source_byte_end'] as int,
                ),
              )
              .trim(),
          localPgnRecordFromSnapshot(text: text, indexInFile: index),
        );
      }
      final next = replaceLocalPgnRecordInSnapshot(
        text: text,
        indexInFile: 1,
        rawPgn: _game(4),
      );
      expect(
        next.substring(0, ranges[1].start),
        text.substring(0, ranges[1].start),
      );
      expect(next, endsWith(text.substring(ranges[2].start)));
    },
  );

  test(
    'failed node returned by post-commit scanner is a saved warning',
    () async {
      await import(_game(0));
      final faultRepo = LocalChessDatabaseRepository(
        database: () async => db,
        debugPostMutationImport:
            (path) async => LocalChessSource(
              id: 'fault',
              label: 'fault',
              paths: [path],
              rootPath: dir.path,
              scannedAt: DateTime.now(),
              root: LocalChessFolderNode.fromChildren(
                name: 'fault',
                path: dir.path,
                relativePath: '',
                children: [
                  LocalChessFileNode(
                    name: 'fixture.pgn',
                    path: path,
                    relativePath: 'fixture.pgn',
                    extension: '.pgn',
                    status: LocalChessFileStatus.failed,
                    games: [],
                    sizeBytes: 0,
                  ),
                ],
              ),
            ),
      );
      final outcome = await updateLocalLibraryPgnGame(
        target: LocalLibraryGameUpdateTarget(
          sourcePath: file.path,
          indexInFile: 0,
          fileGameCount: 1,
          recordRevision: localPgnRecordRevision(_game(0)),
        ),
        game: ChessGame.fromPgn('updated', _game(0, annotation: '{saved}')),
        repository: faultRepo,
      );
      expect(outcome.cacheRefreshWarning, isNotNull);
      final saved = await file.readAsString();
      expect(saved, contains('{ saved }'));
      expect(
        outcome.updateTarget.recordRevision,
        localPgnRecordRevision(saved),
      );
      expect(
        await repo.loadFreshFileNode(file.path, rootPath: dir.path),
        isNull,
      );
    },
  );

  test(
    'custom-header-only external edit rejects stale Board revision',
    () async {
      await import(_game(0));
      final changed = '[Annotator "Other editor"]\n${_game(0)}';
      expect(
        localChessPgnFingerprint(changed),
        localChessPgnFingerprint(_game(0)),
      );
      await file.writeAsString(changed);
      expect(
        await repo.replaceLocalPgnGame(
          databasePath: file.path,
          indexInFile: 0,
          rawPgn: _game(0, annotation: '{stale}'),
          expectedRecordRevision: localPgnRecordRevision(_game(0)),
        ),
        isFalse,
      );
      expect(await file.readAsString(), changed);
    },
  );

  test(
    'delete and update and append overlap without losing unrelated records',
    () async {
      await import('${_game(0)}\n\n${_game(1)}\n');
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = repo.runLocalPgnWriteQueued(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final update = repo.replaceLocalPgnGame(
        databasePath: file.path,
        indexInFile: 0,
        rawPgn: _game(10),
        expectedRecordRevision: localPgnRecordRevision(_game(0)),
      );
      final deletion = repo.removeLocalPgnGames(
        databasePath: file.path,
        indexesInFile: {1},
        expectedRecordRevisions: {1: localPgnRecordRevision(_game(1))},
      );
      final append = appendPgnTextToLocalChessDatabaseFile(
        repository: repo,
        filePath: file.path,
        text: _game(12),
      );
      release.complete();
      await blocker;
      expect(await update, isTrue);
      expect(await deletion, 1);
      expect(await append, 1);
      final text = await file.readAsString();
      expect(pgnGameRanges(text), hasLength(2));
      expect(text, contains('Fixture 10'));
      expect(text, contains('Fixture 12'));
      expect(
        (await repo.loadFreshFileNode(
          file.path,
          rootPath: dir.path,
        ))!.gameCount,
        2,
      );
    },
  );

  test(
    'deleting last record leaves writable empty PGN without false warning',
    () async {
      await import(_game(0));
      expect(
        await repo.removeLocalPgnGames(
          databasePath: file.path,
          indexesInFile: {0},
          expectedRecordRevisions: {0: localPgnRecordRevision(_game(0))},
        ),
        1,
      );
      expect((await file.readAsString()).trim(), isEmpty);
      expect(await db.select('SELECT id FROM local_chess_games'), isEmpty);
    },
  );
  for (final useCache in [false, true]) {
    test('two tabs cannot overwrite annotation saves ($useCache)', () async {
      await import(_game(0));
      final oldTarget = LocalLibraryGameUpdateTarget(
        sourcePath: file.path,
        indexInFile: 0,
        fileGameCount: 1,
        pgnFingerprint: localChessPgnFingerprint(_game(0)),
        recordRevision: localPgnRecordRevision(_game(0)),
      );
      final first = await updateLocalLibraryPgnGame(
        target: oldTarget,
        game: ChessGame.fromPgn('first', _game(0, annotation: '{tab one}')),
        repository: useCache ? repo : null,
      );
      final committed = await file.readAsString();
      expect(first.updateTarget.pgnFingerprint, oldTarget.pgnFingerprint);
      expect(
        first.updateTarget.recordRevision,
        isNot(oldTarget.recordRevision),
      );
      await expectLater(
        updateLocalLibraryPgnGame(
          target: oldTarget,
          game: ChessGame.fromPgn('second', _game(0, annotation: '{tab two}')),
          repository: useCache ? repo : null,
        ),
        throwsStateError,
      );
      expect(await file.readAsString(), committed);
      final again = await updateLocalLibraryPgnGame(
        target: first.updateTarget,
        game: ChessGame.fromPgn(
          'first again',
          _game(0, annotation: '{tab one again}'),
        ),
        repository: useCache ? repo : null,
      );
      expect(again.cacheRefreshWarning, isNull);
      expect(await file.readAsString(), contains('{ tab one again }'));
    });
  }
}
