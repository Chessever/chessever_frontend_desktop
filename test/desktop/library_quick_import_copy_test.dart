import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/library_quick_import.dart';

void main() {
  group('quick folder import limits', () {
    test('large PGNs are rejected before whole-file decoding', () {
      expect(isPgnTooLargeForQuickFolderImport(32 * 1024 * 1024), isFalse);
      expect(isPgnTooLargeForQuickFolderImport((32 * 1024 * 1024) + 1), isTrue);
    });

    test(
      'oversized PGN paths are not claimed by folder quick import',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'chessever-quick-import-',
        );
        addTearDown(() async {
          if (await temp.exists()) {
            await temp.delete(recursive: true);
          }
        });
        final file = File('${temp.path}/large.pgn');
        final sink = file.openWrite();
        sink.add(List<int>.filled((32 * 1024 * 1024) + 1, 0));
        await sink.close();

        expect(canQuickImportPathToFolder(file.path), isFalse);
      },
    );
  });

  group('copyablePgnTextParts', () {
    test('keeps only PGNs that contain moves', () {
      const valid = '''
[Event "Valid"]
[Site "?"]
[Date "2026.06.04"]
[Round "?"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''';
      const headerOnly = '''
[Event "Header only"]
[Site "?"]
[Date "2026.06.04"]
[Round "?"]
[White "White"]
[Black "Black"]
[Result "*"]

*
''';

      final parts = copyablePgnTextParts([
        null,
        '',
        headerOnly,
        '   $valid   ',
      ]);

      expect(parts, [valid.trim()]);
    });
  });

  group('LibraryDropArbiter', () {
    test('claim is consumed once so nested drops suppress outer fallback', () {
      final arbiter = LibraryDropArbiter();

      expect(arbiter.consumeClaim(), isFalse);

      arbiter.claim();

      expect(arbiter.consumeClaim(), isTrue);
      expect(arbiter.consumeClaim(), isFalse);
    });
  });
}
