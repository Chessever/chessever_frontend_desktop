import 'package:chessever/desktop/widgets/event_info_popover.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
