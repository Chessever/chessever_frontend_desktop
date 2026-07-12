import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('right rail starts compact and exposes a visible resize gutter', () {
    final source = File(
      'lib/desktop/widgets/notation_opening_panel.dart',
    ).readAsStringSync();
    final splitStart = source.indexOf("storageKey: 'board_pane.right_rail");
    final splitEnd = source.indexOf('],', splitStart);
    final splitSource = source.substring(splitStart, splitEnd);

    expect(
      splitSource,
      contains("storageKey: 'board_pane.right_rail.engine_top.v2'"),
      reason: 'A new key must discard the old persisted 34/66 split.',
    );
    expect(splitSource, contains('gutterThickness: 10'));
    expect(
      splitSource,
      contains('gutterColor: kWhiteColor.withValues(alpha: 0.12)'),
    );
    expect(splitSource, contains('initialWeight: 0.22'));
    expect(splitSource, contains('initialWeight: 0.78'));
    expect(splitSource, isNot(contains('initialWeight: 0.34')));
  });
}
