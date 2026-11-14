import 'package:chessever/desktop/state/desktop_tabs.dart';

/// Model a mounted work pane with a real active tab. Home's compatibility
/// identity is virtual and must never double as a Board or Play fixture id.
DesktopTabsNotifier realTabFixture({
  String id = 'fixture-board',
  TabKind kind = TabKind.board,
}) => _RealTabFixture(id, kind);

class _RealTabFixture extends DesktopTabsNotifier {
  _RealTabFixture(String id, TabKind kind) {
    assert(id != desktopHomeTabId);
    state = DesktopTabsState(
      tabs: [
        DesktopTab(
          id: id,
          kind: kind,
          title: kind == TabKind.play ? 'Play' : 'Board',
        ),
      ],
      activeId: id,
    );
  }
}
