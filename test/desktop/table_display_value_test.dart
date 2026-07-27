import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/table_display_value.dart';

void main() {
  test('desktop table values omit unavailable metadata markers', () {
    for (final value in const <Object?>[
      null,
      '',
      '   ',
      '?',
      '??',
      '????',
      '-',
      '--',
      '–',
      '—',
      'Unknown',
      'unknown event',
      'Unknown opening',
      'Event',
      'N/A',
      'null',
    ]) {
      expect(desktopTableDisplayValue(value), '', reason: '$value');
    }
  });

  test('desktop table values preserve meaningful metadata', () {
    expect(desktopTableDisplayValue(' C65 '), 'C65');
    expect(desktopTableDisplayValue('1-0'), '1-0');
    expect(desktopTableDisplayValue('New York'), 'New York');
  });

  test('desktop table player values omit generic side placeholders', () {
    expect(desktopTablePlayerValue('White'), '');
    expect(desktopTablePlayerValue('black'), '');
    expect(desktopTablePlayerValue('?'), '');
    expect(desktopTablePlayerValue('White, John'), 'White, John');
  });
}
