import 'dart:io';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Private acceptance inputs are supplied locally, never checked into source.
void main() {
  final path = Platform.environment['CBH_ACCEPTANCE_PGN'];
  final expected = int.tryParse(
    Platform.environment['CBH_ACCEPTANCE_RECORDS'] ?? '',
  );
  test(
    'whole converted database retains physical entries and guiding-text roots',
    () async {
      final source = await scanLocalChessPgnCatalog(path!);
      final catalog = source.root.files.single;
      expect(catalog.gameCount, expected);
      expect(catalog.games.length, expected);
      expect(catalog.pgnOffsetIndex?.totalGames, expected);
      var guiding = 0;
      for (final entry in catalog.games) {
        final raw = entry.rawPgn;
        expect(raw, isNotEmpty, reason: 'entry ${entry.indexInFile}');
        expect(raw, contains('[ChessBaseIndex "'));
        if (entry.game.metadata['ChessBaseRecordType'] == 'GuidingText') {
          guiding++;
          expect(entry.hasMoves, isFalse);
          expect(raw, contains('[ChessBaseGuidingText "'));
          expect(raw, contains('ChessBase guiding text: empty HTML bodies.'));
        }
      }
      expect(guiding, 5);
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: path == null || expected == null
        ? 'Set CBH_ACCEPTANCE_PGN and CBH_ACCEPTANCE_RECORDS for private whole-file acceptance'
        : false,
  );
}
