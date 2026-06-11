import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_pgn_append.dart';

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
  });
}
