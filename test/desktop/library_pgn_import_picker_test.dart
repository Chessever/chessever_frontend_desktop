import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/library_pgn_import_picker.dart';

void main() {
  group('library PGN import picker helpers', () {
    test('extracts non-empty file paths without mutating them', () {
      final result = FilePickerResult(<PlatformFile>[
        PlatformFile(name: 'one.pgn', path: ' /tmp/one.pgn ', size: 10),
        PlatformFile(name: 'web.pgn', size: 10),
        PlatformFile(name: 'blank.pgn', path: '   ', size: 10),
        PlatformFile(name: 'two.pgn', path: '/tmp/two.pgn', size: 10),
      ]);

      expect(libraryPgnImportPathsFromResult(result), <String>[
        ' /tmp/one.pgn ',
        '/tmp/two.pgn',
      ]);
    });

    test('uses filename label for a single PGN', () {
      expect(
        libraryPgnImportSourceLabel(<String>[r'C:\Users\Vasif\test.pgn']),
        'test.pgn',
      );
    });

    test('uses count label for multiple PGNs', () {
      expect(
        libraryPgnImportSourceLabel(<String>['/tmp/one.pgn', '/tmp/two.pgn']),
        '2 PGN files',
      );
    });
  });
}
