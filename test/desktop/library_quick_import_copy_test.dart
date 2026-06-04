import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/library_quick_import.dart';

void main() {
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
}
