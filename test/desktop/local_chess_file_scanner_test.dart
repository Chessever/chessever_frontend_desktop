import 'dart:convert';
import 'dart:io';

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

    test('picker extensions only allow PGN files', () {
      expect(localChessSupportedExtensions, {'.pgn'});
      expect(
        localChessRecognizedExtensions,
        containsAll(localChessSupportedExtensions),
      );
      expect(
        localChessPickerExtensions.toSet(),
        hasLength(localChessPickerExtensions.length),
      );
      expect(localChessPickerExtensions, <String>['pgn']);
      expect(looksLikeLocalChessFile('/tmp/lines.pgn'), isTrue);
      expect(looksLikeLocalChessFile('/tmp/lines.pgn.gz'), isFalse);
      expect(looksLikeLocalChessFile('/tmp/notes.gz'), isFalse);
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

    test('compressed PGN databases are rejected', () async {
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
