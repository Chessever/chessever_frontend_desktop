import 'package:chessever/desktop/widgets/event_info_popover.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('eventInfoDisplayEvent', () {
    test('returns broadcast name when available', () {
      expect(
        eventInfoDisplayEvent({
          'Event': '2026 Titled Tuesday Blitz June 02',
          'BroadcastName': 'Titled Tuesday June 2 2026 - Boards 1-100',
        }),
        'Titled Tuesday June 2 2026 - Boards 1-100',
      );
    });

    test('falls back to event when broadcast name is absent', () {
      expect(
        eventInfoDisplayEvent({'Event': '2026 Titled Tuesday Blitz June 02'}),
        '2026 Titled Tuesday Blitz June 02',
      );
    });
  });

  group('eventInfoDisplayBroadcastName', () {
    test('returns broadcast name when available', () {
      expect(
        eventInfoDisplayBroadcastName({
          'Event': '2026 Titled Tuesday Blitz June 02',
          'BroadcastName': 'Titled Tuesday June 2 2026 - Boards 1-100',
        }),
        'Titled Tuesday June 2 2026 - Boards 1-100',
      );
    });

    test('returns null when broadcast name is absent', () {
      expect(
        eventInfoDisplayBroadcastName({
          'Event': '2026 Titled Tuesday Blitz June 02',
        }),
        isNull,
      );
    });
  });

  group('eventInfoExtraHeaderEntries', () {
    test('surfaces tags without a curated row, alphabetized', () {
      final extras = eventInfoExtraHeaderEntries({
        'Event': 'FIDE World Championship 2024',
        'White': 'Ding, Liren',
        'WhiteTeam': 'China',
        'PlyCount': '6',
        'EventDate': '2024.11.25',
        'WhiteFideId': '8603677',
      });

      expect(extras.map((e) => e.key).toList(), [
        'EventDate',
        'PlyCount',
        'WhiteFideId',
        'WhiteTeam',
      ]);
      expect(extras.first.value, '2024.11.25');
    });

    test('drops app-internal keys and placeholder values', () {
      final extras = eventInfoExtraHeaderEntries({
        'isLiveGame': 'false',
        'allowMainlineExtension': 'true',
        'gameEndingPlyIndex': '12',
        'ChessEverEngineKind': 'stockfish',
        'SourceTitle': '?',
        'Variation': '',
        'EventType': 'match',
      });

      expect(extras, hasLength(1));
      expect(extras.single.key, 'EventType');
      expect(extras.single.value, 'match');
    });

    test('keeps canonical ChessEver links out of the generic rows', () {
      final extras = eventInfoExtraHeaderEntries({
        'ChessEverEventUrl': 'https://chessever.com/broadcast/example/event',
        'ChessEverGameUrl': 'https://chessever.com/games/example',
        'BroadcastURL': 'https://lichess.org/broadcast/example',
        'GameURL': 'https://lichess.org/example',
        'PlyCount': '6',
      });

      expect(extras.map((entry) => entry.key), ['PlyCount']);
    });
  });

  group('eventInfoTagLabel', () {
    test('splits camel case and uppercases known acronyms', () {
      expect(eventInfoTagLabel('WhiteFideId'), 'White FIDE ID');
      expect(eventInfoTagLabel('EventDate'), 'Event Date');
      expect(eventInfoTagLabel('PlyCount'), 'Ply Count');
      expect(eventInfoTagLabel('UTCTime'), 'UTC Time');
      expect(eventInfoTagLabel('SourceTitle'), 'Source Title');
      expect(eventInfoTagLabel('FEN'), 'FEN');
    });
  });

  group('eventInfoSelectedText', () {
    test('returns the selected substring for copy actions', () {
      const value = TextEditingValue(
        text: 'GM Alsina Leal, Daniel (2493)',
        selection: TextSelection(baseOffset: 3, extentOffset: 15),
      );

      expect(eventInfoSelectedText(value), 'Alsina Leal,');
    });

    test('returns null when the text selection is collapsed', () {
      const value = TextEditingValue(
        text: 'Zalakaros, Hungary',
        selection: TextSelection.collapsed(offset: 4),
      );

      expect(eventInfoSelectedText(value), isNull);
    });
  });
}
