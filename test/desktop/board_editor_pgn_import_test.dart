import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/board_editor_pgn_import.dart';
import 'package:chessever/desktop/widgets/board_editor_import_chooser_dialog.dart';

void main() {
  group('board editor PGN import', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_editor_import_');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('parses multiple games from one PGN blob', () {
      final result = parseBoardEditorPgnText(
        _multiGamePgn,
        sourceLabel: 'clipboard',
      );

      expect(result.sourceLabel, 'clipboard');
      expect(result.entries, hasLength(2));
      expect(result.entries.first.rawPgn, contains('[Event "Game One"]'));
      expect(
        result.entries.first.rawPgn,
        isNot(contains('[Event "Game Two"]')),
      );
      expect(result.entries.last.game.metadata['White'], 'Polgar, Judit');
    });

    test('keeps single position PGNs usable for editor FEN loading', () {
      final result = parseBoardEditorPgnText(
        _positionPgn,
        sourceLabel: 'clipboard',
      );

      expect(result.entries, hasLength(1));
      expect(result.entries.single.game.mainline, isEmpty);
      expect(
        result.entries.single.game.startingFen,
        '8/8/8/8/8/8/8/K6k w - - 0 1',
      );
    });

    test('keeps position entries inside multi-game PGN blobs', () {
      final result = parseBoardEditorPgnText(
        '$_multiGamePgn\n\n$_positionPgn',
        sourceLabel: 'clipboard',
      );

      expect(result.entries, hasLength(3));
      expect(result.entries.last.game.mainline, isEmpty);
      expect(
        result.entries.last.game.startingFen,
        '8/8/8/8/8/8/8/K6k w - - 0 1',
      );
    });

    test('scans a selected folder for multi-game PGN files', () async {
      final sub = Directory('${temp.path}/imports');
      await sub.create();
      await File('${sub.path}/multi.pgn').writeAsString(_multiGamePgn);

      final result = await scanBoardEditorLocalChessPaths(<String>[temp.path]);

      expect(result.hasEntries, isTrue);
      expect(result.recognizedFileCount, 1);
      expect(result.unplayableFileCount, 0);
      expect(result.legacyDatabaseShellCount, 0);
      expect(result.entries, hasLength(2));
      expect(result.entries.map((entry) => entry.sourceRelativePath).toSet(), {
        'imports/multi.pgn',
      });
    });

    test('scans a selected folder for FEN and EPD position files', () async {
      final sub = Directory('${temp.path}/prep');
      await sub.create();
      await File(
        '${sub.path}/king.fen',
      ).writeAsString('8/8/8/8/8/8/8/K6k w - - 0 1');
      await File('${sub.path}/start.epd').writeAsString(
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - bm e4;',
      );

      final result = await scanBoardEditorLocalChessPaths(<String>[temp.path]);

      expect(result.hasEntries, isTrue);
      expect(result.recognizedFileCount, 2);
      expect(result.unplayableFileCount, 0);
      expect(result.legacyDatabaseShellCount, 0);
      expect(result.entries, hasLength(2));
      expect(
        result.entries.every((entry) => entry.game.mainline.isEmpty),
        true,
      );
      expect(result.entries.map((entry) => entry.sourceRelativePath).toSet(), {
        'prep/king.fen',
        'prep/start.epd',
      });
      final rawPgns = result.entries.map((entry) => entry.rawPgn).join('\n');
      expect(rawPgns, contains('[FEN "8/8/8/8/8/8/8/K6k w - - 0 1"]'));
      expect(
        rawPgns,
        contains(
          '[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]',
        ),
      );
    });

    test(
      'tracks legacy database shells separately from empty PGN files',
      () async {
        await File('${temp.path}/empty.pgn').writeAsString('');
        await File('${temp.path}/mega.cbv').writeAsString('binary-ish');

        final result = await scanBoardEditorLocalChessPaths(<String>[
          temp.path,
        ]);

        expect(result.hasEntries, isFalse);
        expect(result.recognizedFileCount, 2);
        expect(result.unplayableFileCount, 2);
        expect(result.legacyDatabaseShellCount, 1);
      },
    );

    test('labels and searches mixed game and position choices', () {
      final games = parseBoardEditorPgnText(
        '$_multiGamePgn\n\n$_positionPgn',
        sourceLabel: 'clipboard',
      ).entries;

      expect(boardEditorImportEntryTitle(games.first), contains('Carlsen'));
      expect(boardEditorImportEntryKindLabel(games.first), 'PGN');
      expect(boardEditorImportEntryTitle(games.last), 'Editor Position');
      expect(boardEditorImportEntryKindLabel(games.last), 'POSITION');
      expect(boardEditorImportEntryMatches(games.last, 'K6k'), isTrue);
      expect(boardEditorImportEntryMatches(games.first, 'budapest'), isFalse);
      expect(boardEditorImportEntryMatches(games[1], 'budapest'), isTrue);
    });
  });
}

const _multiGamePgn = '''
[Event "Game One"]
[Site "Toronto"]
[Date "2024.04.04"]
[Round "1"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 1-0

[Event "Game Two"]
[Site "Budapest"]
[Date "2024.05.05"]
[Round "2"]
[White "Polgar, Judit"]
[Black "Anand, Viswanathan"]
[Result "0-1"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 0-1
''';

const _positionPgn = '''
[Event "Editor Position"]
[Site "ChessEver"]
[Date "2024.01.01"]
[White "White"]
[Black "Black"]
[Result "*"]
[FEN "8/8/8/8/8/8/8/K6k w - - 0 1"]
[SetUp "1"]

*
''';
