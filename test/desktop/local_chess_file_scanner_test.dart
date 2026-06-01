import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

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

    test('picker extensions track recognized local chess formats', () {
      expect(
        localChessRecognizedExtensions,
        containsAll(localChessSupportedExtensions),
      );
      expect(
        localChessPickerExtensions.toSet(),
        hasLength(localChessPickerExtensions.length),
      );
      expect(localChessPickerExtensions, contains('gz'));
      expect(localChessPickerExtensions, isNot(contains('pgn.gz')));
      expect(
        localChessPickerExtensions.map((extension) => '.$extension').toSet(),
        {'.pgn', '.gz', '.fen', '.epd', '.cbh', '.cbv', '.cbf'},
      );
      expect(looksLikeLocalChessFile('/tmp/lines.pgn.gz'), isTrue);
      expect(looksLikeLocalChessFile('/tmp/notes.gz'), isFalse);
      expect(looksLikeLocalChessFile('/tmp/archive.zip'), isFalse);
      expect(looksLikeLocalChessFile('/tmp/archive.cbz'), isFalse);
    });

    test('entry count labels cover games and positions', () {
      expect(localChessEntryCountLabel(0), '0 entries');
      expect(localChessEntryCountLabel(1), '1 entry');
      expect(localChessEntryCountLabel(2), '2 entries');
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

    test('marks lone CBH headers as incomplete', () async {
      await File('${temp.path}/mega.cbh').writeAsString('binary-ish');

      final source = await scanLocalChessPaths(<String>[temp.path]);
      final file = source.root.files.single;

      expect(file.extension, '.cbh');
      expect(file.status, LocalChessFileStatus.unsupported);
      expect(file.games, isEmpty);
      expect(file.message, contains('matching .cbg moves file'));
    });

    test('parses CBH databases into playable PGN entries', () async {
      await _writeTinyCbhDatabase(temp.path, 'tiny');

      final source = await scanLocalChessPaths(<String>[
        '${temp.path}/tiny.cbh',
      ]);
      final scanned = source.root.files.single;
      final game = scanned.games.single;

      expect(scanned.extension, '.cbh');
      expect(scanned.status, LocalChessFileStatus.parsed);
      expect(source.root.gameCount, 1);
      expect(game.game.metadata['White'], 'Carlsen, Magnus');
      expect(game.game.metadata['Black'], 'Nakamura, Hikaru');
      expect(game.rawPgn, contains('1. e4 e5 (1... c5) 1-0'));
      expect(game.game.mainline.map((move) => move.uci), <String>[
        'e2e4',
        'e7e5',
      ]);
      expect(game.game.mainline.first.variations, hasLength(1));
      expect(game.game.mainline.first.variations!.single.single.uci, 'c7c5');
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

    test('compressed PGN databases are parsed directly', () async {
      final file = File('${temp.path}/archive.pgn.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode(_samplePgn)));

      final source = await scanLocalChessPaths(<String>[file.path]);
      final scanned = source.root.files.single;

      expect(scanned.extension, '.pgn.gz');
      expect(scanned.status, LocalChessFileStatus.parsed);
      expect(scanned.games.single.game.metadata['Black'], 'Nakamura, Hikaru');
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

    test('FEN and EPD position collections open as local entries', () async {
      final fen = File('${temp.path}/prep.fen');
      await fen.writeAsString('''
8/8/8/8/8/8/8/K6k w - - 0 1
# ignored
invalid fen
''');
      final epd = File('${temp.path}/training.epd');
      await epd.writeAsString(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - bm e4;',
      );

      final source = await scanLocalChessPaths(<String>[fen.path, epd.path]);

      expect(source.root.fileCount, 2);
      expect(source.root.gameCount, 2);
      final positions = source.games;
      expect(positions.first.game.mainline, isEmpty);
      expect(
        positions.first.rawPgn,
        contains('[FEN "8/8/8/8/8/8/8/K6k w - - 0 1"]'),
      );
      expect(
        positions.last.game.startingFen,
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
    });
  });
}

Future<void> _writeTinyCbhDatabase(String directory, String name) async {
  await File('$directory/$name.cbh').writeAsBytes(_tinyCbhBytes());
  await File('$directory/$name.cbg').writeAsBytes(_tinyCbgBytes());
  await File('$directory/$name.cbp').writeAsBytes(_tinyCbpBytes());
  await File('$directory/$name.cbt').writeAsBytes(_tinyCbtBytes());
}

List<int> _tinyCbhBytes() {
  final bytes = Uint8List(46 * 2);
  final record = 46;
  bytes[record] = 0x01; // game record
  _writeU32(bytes, record + 1, 0); // game offset in .cbg
  _writeU24(bytes, record + 9, 0); // white player
  _writeU24(bytes, record + 12, 1); // black player
  _writeU24(bytes, record + 15, 0); // tournament
  _writeU24(bytes, record + 24, (2024 << 9) | (4 << 5) | 4);
  bytes[record + 27] = 2; // 1-0
  bytes[record + 29] = 1; // round
  _writeU16(bytes, record + 31, 2830);
  _writeU16(bytes, record + 33, 2780);
  return bytes;
}

List<int> _tinyCbgBytes() {
  final bytes = Uint8List(10);
  _writeU32(bytes, 0, 10);
  bytes[4] = 0xFF; // e2-e4
  bytes[5] = 0xDD; // variation start: 0xdc plus processed-move offset 1
  bytes[6] = 0xDB; // c7-c5 in variation: 0xda plus processed-move offset 1
  bytes[7] = 0x0E; // variation end: 0x0c plus processed-move offset 2
  bytes[8] = 0x01; // e7-e5: 0xff plus processed-move offset 2
  bytes[9] = 0x0F; // final 0x0c marker plus processed-move offset 3
  return bytes;
}

List<int> _tinyCbpBytes() {
  final bytes = Uint8List(28 + (2 * 67));
  bytes[0x18] = 0;
  _writeCbpPlayer(bytes, 0, last: 'Carlsen', first: 'Magnus');
  _writeCbpPlayer(bytes, 1, last: 'Nakamura', first: 'Hikaru');
  return bytes;
}

List<int> _tinyCbtBytes() {
  final bytes = Uint8List(28 + 99);
  bytes[0x18] = 0;
  const offset = 28;
  _writeAscii(bytes, offset + 9, 40, 'Candidates');
  _writeAscii(bytes, offset + 49, 30, 'Toronto');
  return bytes;
}

void _writeCbpPlayer(
  Uint8List bytes,
  int player, {
  required String last,
  required String first,
}) {
  final offset = 28 + (player * 67);
  _writeAscii(bytes, offset + 9, 30, last);
  _writeAscii(bytes, offset + 39, 20, first);
}

void _writeAscii(Uint8List bytes, int offset, int length, String value) {
  final encoded = ascii.encode(value);
  final count = encoded.length < length ? encoded.length : length;
  bytes.setRange(offset, offset + count, encoded.take(count));
}

void _writeU16(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 8) & 0xff;
  bytes[offset + 1] = value & 0xff;
}

void _writeU24(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 16) & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = value & 0xff;
}

void _writeU32(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 24) & 0xff;
  bytes[offset + 1] = (value >> 16) & 0xff;
  bytes[offset + 2] = (value >> 8) & 0xff;
  bytes[offset + 3] = value & 0xff;
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
