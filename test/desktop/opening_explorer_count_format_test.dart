import 'package:chessever/desktop/widgets/desktop_opening_explorer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats explorer game totals compactly', () {
    expect(formatExplorerGameCount(897), '897');
    expect(formatExplorerGameCount(58400), '58.4k');
    expect(formatExplorerGameCount(58490), '58.5k');
    expect(formatExplorerGameCount(1240000), '1.2m');
  });
}