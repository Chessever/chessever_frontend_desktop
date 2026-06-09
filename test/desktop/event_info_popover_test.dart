import 'package:chessever/desktop/widgets/event_info_popover.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('eventInfoDisplayEvent', () {
    test('keeps raw event when broadcast name exists', () {
      expect(
        eventInfoDisplayEvent({
          'Event': '2026 Titled Tuesday Blitz June 02',
          'BroadcastName': 'Titled Tuesday June 2 2026 - Boards 1-100',
        }),
        '2026 Titled Tuesday Blitz June 02',
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
