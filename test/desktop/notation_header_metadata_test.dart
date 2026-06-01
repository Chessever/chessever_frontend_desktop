import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/notation_ladder_view.dart';

void main() {
  group('notationHeaderMetadataFromPgn', () {
    test('keeps only compact event/date/opening-code metadata', () {
      final metadata = notationHeaderMetadataFromPgn({
        'Event': ' Tata Steel Masters ',
        'Site': 'Wijk aan Zee',
        'Round': '7.1',
        'Date': '2026.01.24',
        'ECO': 'C42',
        'White': 'White Player',
        'Black': 'Black Player',
        'WhiteElo': '2800',
        'BlackElo': '2700',
        'Result': '1-0',
      });

      expect(metadata.event, 'Tata Steel Masters');
      expect(metadata.round, '7.1');
      expect(metadata.date, '2026.01.24');
      expect(metadata.eco, 'C42');
    });

    test('treats empty and unknown PGN values as absent', () {
      final metadata = notationHeaderMetadataFromPgn({
        'Event': '?',
        'Round': ' ',
        'Date': '',
        'ECO': '?',
      });

      expect(metadata.hasAny, isFalse);
      expect(metadata.event, isNull);
      expect(metadata.round, isNull);
      expect(metadata.date, isNull);
      expect(metadata.eco, isNull);
    });
  });
}
