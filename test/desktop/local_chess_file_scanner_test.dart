import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:libcompress/libcompress.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  group('local chess file scanner', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_local_scan_');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('picker extensions allow raw and compressed PGN files', () {
      expect(localChessSupportedExtensions, {
        '.pgn',
        '.pgn.bz2',
        '.pgn.zst',
        '.bz2',
        '.zst',
      });
      expect(
        localChessRecognizedExtensions,
        containsAll(localChessSupportedExtensions),
      );
      expect(
        localChessPickerExtensions.toSet(),
        hasLength(localChessPickerExtensions.length),
      );
      expect(localChessPickerExtensions, <String>['pgn', 'bz2', 'zst']);
      expect(looksLikeLocalChessFile('/tmp/lines.pgn'), isTrue);
      expect(looksLikeLocalChessFile('/tmp/lines.pgn.bz2'), isTrue);
      expect(looksLikeLocalChessFile('/tmp/lines.pgn.zst'), isTrue);
      expect(looksLikeLocalChessFile('/tmp/lines.pgn.gz'), isFalse);
      expect(looksLikeLocalChessFile('/tmp/notes.bz2'), isTrue);
      expect(looksLikeLocalChessFile('/tmp/notes.zst'), isTrue);
      expect(looksLikeLocalChessFile('/tmp/archive.zip'), isFalse);
      expect(looksLikeLocalChessFile('/tmp/archive.cbz'), isFalse);
      expect(looksLikeLocalChessFile('/tmp/mega.cbh'), isTrue);
      expect(isSupportedLocalChessFile('/tmp/mega.cbh'), isFalse);
    });

    test('entry count labels cover games and positions', () {
      expect(localChessEntryCountLabel(0), '0 entries');
      expect(localChessEntryCountLabel(1), '1 entry');
      expect(localChessEntryCountLabel(2), '2 entries');
    });

    test('database display names are derived from polished file names', () {
      expect(
        localChessDatabaseDisplayNameForPath('/tmp/idc_2053.pgn'),
        'IDC_2053.pgn',
      );
      expect(
        localChessDatabaseDisplayNameForPath('/tmp/hikaru_chesscom.pgn'),
        'Hikaru_Chesscom.pgn',
      );
      expect(localChessDatabaseDisplayNameForPath('/tmp/mini.pgn'), 'mini.pgn');
    });

    test('database source labels are derived from local paths', () {
      expect(
        localChessDatabaseDisplayNameForPaths(<String>['/tmp/idc_2053.pgn']),
        'IDC_2053.pgn',
      );
      expect(
        localChessDatabaseDisplayNameForPaths(<String>[
          r'C:\Users\Vasif\one.pgn',
          '/tmp/two.pgn',
        ]),
        '2 PGN files',
      );
      expect(
        localChessDatabaseDisplayNameForPaths(<String>[
          '/tmp/archive.pgn.zst',
          '/tmp/database-folder',
        ]),
        '2 local databases',
      );
    });

    test('input path identity follows Windows filesystem semantics', () {
      expect(
        localChessInputPathKey(r'C:\DB\Games\..\Round.PGN', windows: true),
        r'c:\db\round.pgn',
      );
      expect(
        dedupeLocalChessInputPaths(<String>[
          r'C:\DB\Round.PGN',
          r'c:/db/round.pgn',
          r'C:\DB\Other.pgn',
        ], windows: true),
        <String>[r'C:\DB\Other.pgn', r'C:\DB\Round.PGN'],
      );
    });

    test(
      'recursively parses PGN files and preserves folder structure',
      () async {
        final sub = Directory('${temp.path}/Candidates');
        await sub.create();
        await File('${sub.path}/round-1.pgn').writeAsString(_samplePgn);

        final source = await scanLocalChessPaths(<String>[temp.path]);

        expect(source.root.fileCount, 1);
        expect(source.root.gameCount, 1);
        expect(source.games.single.game.metadata['White'], 'Carlsen, Magnus');
        expect(
          source.games.single.sourceRelativePath,
          'Candidates/round-1.pgn',
        );
        expect(source.root.folders.single.name, 'Candidates');
      },
    );

    test('marks ChessBase database formats as unsupported', () async {
      await File('${temp.path}/mega.cbh').writeAsString('binary-ish');

      final source = await scanLocalChessPaths(<String>[temp.path]);
      final file = source.root.files.single;

      expect(file.extension, '.cbh');
      expect(file.status, LocalChessFileStatus.unsupported);
      expect(file.games, isEmpty);
      expect(
        file.message,
        'Only PGN databases are currently supported. Please export this database as PGN and import the PGN file.',
      );
    });

    test('single PGN file opens as a one-file source', () async {
      final file = File('${temp.path}/mini.pgn');
      await file.writeAsString(_samplePgn);

      final source = await scanLocalChessPaths(<String>[file.path]);

      expect(source.label, 'mini.pgn');
      expect(source.root.name, 'mini.pgn');
      expect(source.root.path, startsWith('local-file:'));
      expect(source.root.files.single.games.single.title, contains('Carlsen'));
      expect(source.root.gameCount, 1);
      expect(source.nodeForPath(file.path), same(source.root.files.single));
      expect(source.nodeForPath('${temp.path}/other.pgn'), isNull);
    });

    test(
      'local opening tree defaults to 50 ply for normal and large imports',
      () {
        expect(localOpeningTreeDefaultMaxPly, 50);
        expect(
          localOpeningTreeLargeImportMaxPly,
          localOpeningTreeDefaultMaxPly,
        );
      },
    );

    test('normal PGN imports build tree moves at the 50 ply limit', () async {
      final pgn = _repeatingKnightPgn(fullMoves: 30);
      final file = File('${temp.path}/deep-small.pgn');
      await file.writeAsString(pgn);

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;
      final index = scanned.openingTreeIndex!;
      final game = ChessGame.fromPgn('deep-small', pgn);
      final fenBeforePly50 = game.mainline[48].fen;

      expect(index.maxPly, 50);
      expect(
        index.movesForFen(fenBeforePly50).map((move) => move.uci),
        contains(game.mainline[49].uci),
      );
    });

    test('large PGN tree skips eager position refs but keeps moves', () async {
      final file = File('${temp.path}/bulk-tree.pgn');
      final pgn = StringBuffer();
      for (var i = 0; i < 10001; i++) {
        pgn
          ..writeln('[Event "Bulk Tree $i"]')
          ..writeln('[Site "ChessEver"]')
          ..writeln('[Date "2026.06.28"]')
          ..writeln('[Round "$i"]')
          ..writeln('[White "White $i"]')
          ..writeln('[Black "Black $i"]')
          ..writeln('[Result "1-0"]')
          ..writeln()
          ..writeln('1. e4 e5 2. Nf3 Nc6 1-0')
          ..writeln();
      }
      await file.writeAsString(pgn.toString());

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;
      final index = scanned.openingTreeIndex!;

      expect(scanned.gameCount, 10001);
      expect(index.downloadedGameCount, 10001);
      expect(index.gamesByFen, isEmpty);
      expect(index.gameRowsById, isEmpty);
      expect(
        index
            .movesForFen(
              'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
            )
            .map((move) => move.uci),
        contains('e2e4'),
      );
    });

    test(
      'raw PGN files stream past the compressed decode byte limit',
      () async {
        final file = File('${temp.path}/large-raw.pgn');
        await file.writeAsString(
          List<String>.filled(20, _samplePgn).join('\n\n'),
        );

        final source = await scanLocalChessPaths(
          <String>[file.path],
          maxDecodedBytes: 1024,
          maxGames: 2,
        );
        final scanned = source.root.files.single;

        expect(scanned.sizeBytes, greaterThan(1024));
        expect(scanned.status, LocalChessFileStatus.parsed);
        expect(scanned.games, hasLength(1));
        expect(scanned.games.first.fileGameCount, 20);
        expect(scanned.message, contains('Showing first 1 of 20 entries'));
        expect(scanned.message, contains('Skipped 1 duplicate PGN entry'));
        expect(scanned.openingTreeIndex, isNotNull);
      },
    );

    test('raw PGN scans expose byte checkpoints and game ranges', () async {
      final file = File('${temp.path}/offsets.pgn');
      await file.writeAsBytes(<int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(
          '$_samplePgn\n\n$_secondSamplePgn'.replaceAll('\n', '\r\n'),
        ),
      ]);

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;
      final index = scanned.pgnOffsetIndex;
      final bytes = await file.readAsBytes();

      expect(index, isNotNull);
      expect(index!.totalGames, 2);
      expect(index.checkpointStride, greaterThan(1));
      expect(
        index.checkpointOffsetForGame(0),
        scanned.games.first.sourceByteStart,
      );
      expect(index.checkpointGameIndexForGame(1), 0);
      expect(
        utf8.decode(
          bytes.sublist(
            scanned.games.first.sourceByteStart!,
            scanned.games.first.sourceByteStart! + '[Event'.length,
          ),
        ),
        '[Event',
      );

      final secondStart = scanned.games.last.sourceByteStart!;
      final secondEnd = scanned.games.last.sourceByteEnd!;
      final secondRaw = utf8.decode(bytes.sublist(secondStart, secondEnd));
      expect(secondRaw.trim(), scanned.games.last.rawPgn);
      expect(secondRaw, contains('[White "Polgar, Judit"]'));

      final rangeBackedGame = LocalChessGame(
        id: 'range-backed',
        game: scanned.games.last.game,
        rawPgn: '',
        sourcePath: file.path,
        sourceRelativePath: scanned.games.last.sourceRelativePath,
        fileName: scanned.games.last.fileName,
        indexInFile: scanned.games.last.indexInFile,
        fileGameCount: scanned.games.last.fileGameCount,
        hasMoves: scanned.games.last.hasMoves,
        sourceByteStart: secondStart,
        sourceByteEnd: secondEnd,
      );
      expect(rangeBackedGame.rawPgn, secondRaw.trim());
    });

    test('raw PGN byte scanner handles CR-only line endings', () async {
      final file = File('${temp.path}/classic-mac.pgn');
      await file.writeAsString(
        '$_samplePgn\n\n$_secondSamplePgn'.replaceAll('\n', '\r'),
      );

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.status, LocalChessFileStatus.parsed);
      expect(scanned.games, hasLength(2));
      expect(scanned.pgnOffsetIndex?.totalGames, 2);
      expect(scanned.games.last.game.metadata['White'], 'Polgar, Judit');
    });

    test(
      'empty parseable files use entry copy in no-playable messages',
      () async {
        final file = File('${temp.path}/empty.pgn');
        await file.writeAsString('');

        final source = await scanLocalChessPaths(<String>[file.path]);
        final scanned = source.root.files.single;

        expect(scanned.status, LocalChessFileStatus.noGames);
        expect(scanned.message, 'No playable entries were found.');
      },
    );

    test('one PGN file can contain multiple games', () async {
      final file = File('${temp.path}/multi.pgn');
      await file.writeAsString('$_samplePgn\n\n$_secondSamplePgn');

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.status, LocalChessFileStatus.parsed);
      expect(scanned.games, hasLength(2));
      expect(scanned.games.map((game) => game.indexInFile), <int>[0, 1]);
      expect(scanned.games.map((game) => game.fileGameCount), <int>[2, 2]);
      expect(scanned.games.last.game.metadata['White'], 'Polgar, Judit');
    });

    test(
      'dedupes duplicate PGNs while preserving original file indexes',
      () async {
        final file = File('${temp.path}/dedupe.pgn');
        const first = '''
[Event "Dedupe"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 e5 1-0
''';
        const duplicate = '''
[Event "Dedupe"]
[White "A"]
[Black "B"]
[Result "1-0"]

1.   e4   e5 1-0
''';
        const fresh = '''
[Event "Fresh"]
[White "C"]
[Black "D"]
[Result "0-1"]

1. d4 Nf6 0-1
''';
        await file.writeAsString('$first\n\n$duplicate\n\n$fresh');

        final source = await scanLocalChessPaths(<String>[file.path]);
        final scanned = source.root.files.single;

        expect(scanned.status, LocalChessFileStatus.parsed);
        expect(scanned.games, hasLength(2));
        expect(scanned.games.map((game) => game.indexInFile), <int>[0, 2]);
        expect(scanned.games.map((game) => game.fileGameCount).toSet(), {3});
        expect(
          scanned.games.map((game) => game.pgnFingerprint).toSet(),
          hasLength(2),
        );
        expect(scanned.message, contains('Skipped 1 duplicate PGN entry'));
        expect(scanned.openingTreeIndex!.downloadedGameCount, 2);
      },
    );

    test(
      'dedupes imported PGNs with equivalent SAN spelling and reordered headers',
      () async {
        final file = File('${temp.path}/san-dedupe.pgn');
        const first = '''
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

1. e4 {comment} e5 2. Nf3 (2. Bc4) Nc6 3. Bc4 Bc5 4. O-O Nf6 5. Re1 1-0
''';
        const fresh = '''
[Event "Fresh"]
[White "C"]
[Black "D"]
[Result "0-1"]

1. c4 c5 0-1
''';
        await file.writeAsString('$first\n\n$duplicate\n\n$fresh');

        final source = await scanLocalChessPaths(<String>[file.path]);
        final scanned = source.root.files.single;

        expect(scanned.status, LocalChessFileStatus.parsed);
        expect(scanned.games, hasLength(2));
        expect(scanned.games.map((game) => game.indexInFile), <int>[0, 2]);
        expect(scanned.message, contains('Skipped 1 duplicate PGN entry'));
      },
    );

    test('splits games even when later PGNs do not start with Event', () async {
      final file = File('${temp.path}/missing-event-boundary.pgn');
      await file.writeAsString('$_samplePgn\n\n$_whiteFirstPgn');

      final source = await scanLocalChessPaths(<String>[file.path]);
      final games = source.root.files.single.games;

      expect(games, hasLength(2));
      expect(games.last.game.metadata['White'], 'Gukesh, D');
      expect(games.last.game.metadata['Black'], 'Keymer, Vincent');
      expect(games.last.game.metadata['Date'], '2026.06.02');
      expect(games.last.game.metadata['Event'], '14th Norway Chess 2026');
    });

    test(
      'folder selection auto-resolves only when one playable database exists',
      () async {
        final sub = Directory('${temp.path}/Only');
        await sub.create();
        await File('${sub.path}/single.pgn').writeAsString(_samplePgn);
        await File('${temp.path}/readme.cbf').writeAsString('recognized only');

        final source = await scanLocalChessPaths(<String>[temp.path]);
        final selected = selectedLocalChessDatabaseFile(source.root);

        expect(source.root.playableDatabaseCount, 1);
        expect(selected, isNotNull);
        expect(selected!.name, 'single.pgn');
        expect(selected.games, hasLength(1));
        expect(selected.games.single.sourceRelativePath, 'Only/single.pgn');
      },
    );

    test('folder selection does not aggregate multiple databases', () async {
      final first = File('${temp.path}/a.pgn');
      final second = File('${temp.path}/b.pgn');
      await first.writeAsString(_samplePgn);
      await second.writeAsString(_secondSamplePgn);

      final source = await scanLocalChessPaths(<String>[temp.path]);

      expect(source.root.playableDatabaseCount, 2);
      expect(source.root.gameCount, 2);
      expect(selectedLocalChessDatabaseFile(source.root), isNull);
      expect(
        selectedLocalChessDatabaseFile(source.root.files.first)?.games,
        hasLength(1),
      );
    });

    test('parses bzip2-compressed PGN databases', () async {
      final file = File('${temp.path}/archive.bz2');
      await file.writeAsBytes(
        BZip2Encoder().encodeBytes(utf8.encode(_samplePgn)),
      );

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.extension, '.bz2');
      expect(scanned.status, LocalChessFileStatus.parsed);
      expect(scanned.games.single.game.metadata['White'], 'Carlsen, Magnus');
      expect(scanned.openingTreeIndex, isNotNull);
    });

    test('parses zstd-compressed PGN databases', () async {
      final file = File('${temp.path}/archive.zst');
      await file.writeAsBytes(
        ZstdCodec().compress(Uint8List.fromList(utf8.encode(_samplePgn))),
      );

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.extension, '.zst');
      expect(scanned.status, LocalChessFileStatus.parsed);
      expect(scanned.games.single.game.metadata['White'], 'Carlsen, Magnus');
      expect(scanned.openingTreeIndex, isNotNull);
    });

    test('corrupt bzip2-compressed PGNs report a failed file', () async {
      final file = File('${temp.path}/broken.pgn.bz2');
      await file.writeAsBytes(<int>[0x42, 0x5a, 0x68, 0x39, 0x00]);

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.extension, '.pgn.bz2');
      expect(scanned.status, LocalChessFileStatus.failed);
      expect(scanned.games, isEmpty);
      expect(scanned.message, contains('Could not decode compressed PGN'));
    });

    test('corrupt simple bzip2 PGNs keep their extension in errors', () async {
      final file = File('${temp.path}/broken.bz2');
      await file.writeAsBytes(<int>[0x42, 0x5a, 0x68, 0x39, 0x00]);

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.extension, '.bz2');
      expect(scanned.status, LocalChessFileStatus.failed);
      expect(scanned.message, contains('(.bz2)'));
      expect(scanned.message, isNot(contains('(.pgn.bz2)')));
    });

    test('corrupt compressed PGN does not abort directory siblings', () async {
      final first = File('${temp.path}/a.pgn');
      final broken = File('${temp.path}/b.pgn.bz2');
      final second = File('${temp.path}/c.pgn');
      await first.writeAsString(_samplePgn);
      await broken.writeAsBytes(<int>[0x42, 0x5a, 0x68, 0x39, 0x00]);
      await second.writeAsString(_secondSamplePgn);

      final source = await scanLocalChessPaths(<String>[temp.path]);
      final failed = source.nodeForPath(broken.path);
      expect(failed, isA<LocalChessFileNode>());
      final failedFile = failed! as LocalChessFileNode;

      expect(source.root.gameCount, 2);
      expect(source.nodeForPath(first.path), isA<LocalChessFileNode>());
      expect(source.nodeForPath(second.path), isA<LocalChessFileNode>());
      expect(failedFile.status, LocalChessFileStatus.failed);
      expect(failedFile.message, contains('Could not decode compressed PGN'));
    });

    test('corrupt zstd-compressed PGNs report a failed file', () async {
      final file = File('${temp.path}/broken.pgn.zst');
      await file.writeAsBytes(<int>[0x28, 0xb5, 0x2f, 0xfd, 0x00]);

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.extension, '.pgn.zst');
      expect(scanned.status, LocalChessFileStatus.failed);
      expect(scanned.games, isEmpty);
      expect(scanned.message, contains('Could not decode compressed PGN'));
    });

    test('oversized zstd-compressed PGNs report the scan limit', () async {
      final file = File('${temp.path}/huge.pgn.zst');
      await file.writeAsBytes(_zstdFrameDeclaringSize(64 * 1024 * 1024 + 1));

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.extension, '.pgn.zst');
      expect(scanned.status, LocalChessFileStatus.unsupported);
      expect(scanned.games, isEmpty);
      expect(scanned.message, contains('over the 64 MB scan limit'));
    });

    test('gzip-compressed PGN databases are rejected', () async {
      final file = File('${temp.path}/archive.pgn.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode(_samplePgn)));

      await expectLater(
        scanLocalChessPaths(<String>[file.path]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'generic gz files are rejected instead of opened as empty sources',
      () async {
        final file = File('${temp.path}/notes.gz');
        await file.writeAsBytes(gzip.encode(utf8.encode('not a PGN database')));

        await expectLater(
          scanLocalChessPaths(<String>[file.path]),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('batches with no recognized files are rejected', () async {
      final first = File('${temp.path}/notes.txt');
      final second = File('${temp.path}/notes.gz');
      await first.writeAsString('not chess');
      await second.writeAsBytes(gzip.encode(utf8.encode('not chess')));

      await expectLater(
        scanLocalChessPaths(<String>[first.path, second.path]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('zip and CBZ archives are ignored as non-chess intake', () async {
      final zip = File('${temp.path}/database.zip');
      final cbz = File('${temp.path}/shared.cbz');
      await zip.writeAsBytes(const <int>[80, 75, 3, 4]);
      await cbz.writeAsBytes(const <int>[80, 75, 3, 4]);

      await expectLater(
        scanLocalChessPaths(<String>[zip.path, cbz.path]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('FEN and EPD position collections are rejected', () async {
      final fen = File('${temp.path}/prep.fen');
      await fen.writeAsString('8/8/8/8/8/8/8/K6k w - - 0 1');
      final epd = File('${temp.path}/training.epd');
      await epd.writeAsString(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - bm e4;',
      );

      await expectLater(
        scanLocalChessPaths(<String>[fen.path, epd.path]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

Uint8List _zstdFrameDeclaringSize(int size) {
  final bytes = Uint8List(13);
  bytes.setAll(0, <int>[0x28, 0xb5, 0x2f, 0xfd, 0xe0]);
  ByteData.view(bytes.buffer).setUint64(5, size, Endian.little);
  return bytes;
}

String _repeatingKnightPgn({required int fullMoves}) {
  final moves = StringBuffer();
  for (var move = 1; move <= fullMoves; move++) {
    final whiteSan = move.isOdd ? 'Nf3' : 'Ng1';
    final blackSan = move.isOdd ? 'Nf6' : 'Ng8';
    moves.write('$move. $whiteSan $blackSan ');
  }
  return '''
[Event "Depth Limit"]
[Site "Local"]
[Date "2026.06.28"]
[Round "1"]
[White "Depth"]
[Black "Limit"]
[Result "*"]

${moves.toString().trim()} *
''';
}

const _samplePgn = '''
[Event "Candidates"]
[Site "Toronto"]
[Date "2024.04.04"]
[Round "1"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[Result "1-0"]
[WhiteElo "2830"]
[BlackElo "2780"]
[ECO "C65"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O Be7 5. Re1 b5 1-0
''';

const _secondSamplePgn = '''
[Event "Training"]
[Site "Budapest"]
[Date "2024.05.05"]
[Round "2"]
[White "Polgar, Judit"]
[Black "Anand, Viswanathan"]
[Result "0-1"]
[WhiteElo "2675"]
[BlackElo "2750"]
[ECO "B90"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 0-1
''';

const _whiteFirstPgn = '''
[White "Gukesh, D"]
[Black "Keymer, Vincent"]
[Date "2026.06.02"]
[Event "14th Norway Chess 2026"]
[Result "1/2-1/2"]
[WhiteElo "2732"]
[BlackElo "2759"]
[Opening "Two knights defence (Modern bishop's opening)"]

1. e4 e5 2. Bc4 Nf6 1/2-1/2
''';
