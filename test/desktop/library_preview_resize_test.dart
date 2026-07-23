import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Library preview divider can be dragged down to shrink the preview', () {
    final source =
        File('lib/desktop/panes/library_pane.dart').readAsStringSync();
    final cappedHomeSplit = RegExp(
      r"SplitChild\(\s*minSize: 124,\s*maxSize: 220,\s*initialWeight: 0\.24,",
    );

    expect(
      source,
      isNot(matches(cappedHomeSplit)),
      reason:
          'The My Databases pane must not cap its height; that cap prevents '
          'dragging the preview divider downward.',
    );
  });
}
