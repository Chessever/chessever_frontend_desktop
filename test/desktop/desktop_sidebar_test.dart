import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';

void main() {
  test('Board sidebar entry opens the regular board pane', () {
    expect(debugDesktopSidebarPaneForLabel('Board'), DesktopPane.board);
  });

  test('Board Editor is launched from board context, not the sidebar', () {
    expect(debugDesktopSidebarPaneForLabel('Board Editor'), isNull);
  });
  test('Feedback report entry appears directly under Play', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels[labels.indexOf('Play') + 1], 'Feedback / Report issue');
  });

  test('Search appears as the last sidebar action', () {
    final labels = debugDesktopSidebarLabelsInOrder();

    expect(labels.last, 'Search');
  });

  test('Search entry is an action, not a pane route', () {
    expect(debugDesktopSidebarPaneForLabel('Search'), isNull);
  });

  test('Feedback report entry is an action, not a pane route', () {
    expect(debugDesktopSidebarPaneForLabel('Feedback / Report issue'), isNull);
  });
}
