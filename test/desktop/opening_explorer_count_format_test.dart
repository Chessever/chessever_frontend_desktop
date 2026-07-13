import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_opening_explorer.dart';

void main() {
  test('Opening Explorer uses one-decimal compact game totals', () {
    expect(formatOpeningExplorerGameCount(999), '999');
    expect(formatOpeningExplorerGameCount(1000), '1.0k');
    expect(formatOpeningExplorerGameCount(58400), '58.4k');
    expect(formatOpeningExplorerGameCount(999950), '1.0M');
    expect(formatOpeningExplorerGameCount(1200000), '1.2M');
  });
}
