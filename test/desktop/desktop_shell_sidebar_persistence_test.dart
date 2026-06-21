import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/desktop_shell.dart';

void main() {
  group('desktop sidebar selection persistence', () {
    test(
      'keeps manually expanded desktop sidebar open after pane selection',
      () {
        expect(
          shouldCollapseDesktopSidebarAfterPaneSelection(
            autoCollapsed: false,
            sidebarExpanded: true,
            selectedCurrentPane: false,
            inNewTab: false,
          ),
          isFalse,
        );
      },
    );

    test(
      'keeps desktop sidebar open for current pane and new-tab selections',
      () {
        expect(
          shouldCollapseDesktopSidebarAfterPaneSelection(
            autoCollapsed: false,
            sidebarExpanded: true,
            selectedCurrentPane: true,
            inNewTab: false,
          ),
          isFalse,
        );
        expect(
          shouldCollapseDesktopSidebarAfterPaneSelection(
            autoCollapsed: false,
            sidebarExpanded: true,
            selectedCurrentPane: false,
            inNewTab: true,
          ),
          isFalse,
        );
      },
    );

    test('collapses compact drawer after normal pane selection', () {
      expect(
        shouldCollapseDesktopSidebarAfterPaneSelection(
          autoCollapsed: true,
          sidebarExpanded: true,
          selectedCurrentPane: false,
          inNewTab: false,
        ),
        isTrue,
      );
    });
  });
}
