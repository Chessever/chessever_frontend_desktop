import 'package:chessever/desktop/utils/eco_input_formatter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeEcoCode', () {
    test('upper-cases a valid code', () {
      expect(sanitizeEcoCode('b03'), 'B03');
      expect(sanitizeEcoCode('c'), 'C');
    });

    test('requires an A-E letter first', () {
      expect(sanitizeEcoCode('123'), '');
      expect(sanitizeEcoCode('xyz'), '');
      expect(sanitizeEcoCode('9b0'), 'B0');
    });

    test('keeps at most two digits after the letter', () {
      expect(sanitizeEcoCode('B0345'), 'B03');
      expect(sanitizeEcoCode('Bxyz1'), 'B1');
    });
  });

  test('EcoCodeInputFormatter blocks invalid keystrokes', () {
    const formatter = EcoCodeInputFormatter();
    String format(String text) => formatter
        .formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        )
        .text;

    expect(format('zzz'), '');
    expect(format('7'), '');
    expect(format('C50'), 'C50');
  });
}
