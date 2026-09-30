import 'package:chessever/desktop/state/user_move_nags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toggleNag keeps one user NAG per category', () {
    final notifier = UserMoveNagsNotifier();

    notifier.toggleNag('tab-1', 2, 3);
    expect(notifier.state['tab-1']![2], [3]);

    notifier.toggleNag('tab-1', 2, 1);
    expect(notifier.state['tab-1']![2], [1]);

    notifier.toggleNag('tab-1', 2, 16);
    expect(notifier.state['tab-1']![2], [1, 16]);

    notifier.toggleNag('tab-1', 2, 17);
    expect(notifier.state['tab-1']![2], [1, 17]);

    notifier.toggleNag('tab-1', 2, 17);
    expect(notifier.state['tab-1']![2], [1]);
  });

  test('classification NAGs share the move-quality slot', () {
    final notifier = UserMoveNagsNotifier();

    notifier.toggleNag('tab-1', 2, 1);
    notifier.toggleNag('tab-1', 2, 242);
    expect(notifier.state['tab-1']![2], [242]);

    notifier.toggleNag('tab-1', 2, 247);
    expect(notifier.state['tab-1']![2], [247]);

    notifier.toggleNag('tab-1', 2, 243);
    expect(notifier.state['tab-1']![2], [243]);

    notifier.toggleNag('tab-1', 2, 243);
    expect(notifier.state, isEmpty);
  });

  test('clearNags removes a move entry', () {
    final notifier = UserMoveNagsNotifier();

    notifier.setNags('tab-1', 0, [3, 16, 140]);
    notifier.clearNags('tab-1', 0);

    expect(notifier.state, isEmpty);
  });
}
