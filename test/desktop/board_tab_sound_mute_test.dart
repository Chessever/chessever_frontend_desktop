import 'package:chessever/desktop/state/board_tab_sound_mute.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toggle mutes and unmutes a single board tab', () {
    final notifier = BoardTabSoundMuteNotifier();

    expect(notifier.isMuted('tab-a'), isFalse);

    notifier.toggle('tab-a');
    expect(notifier.isMuted('tab-a'), isTrue);
    expect(notifier.isMuted('tab-b'), isFalse);

    notifier.toggle('tab-a');
    expect(notifier.isMuted('tab-a'), isFalse);
  });

  test('clear removes closed tab mute state only', () {
    final notifier = BoardTabSoundMuteNotifier();

    notifier.setMuted('tab-a', true);
    notifier.setMuted('tab-b', true);
    notifier.clear('tab-a');

    expect(notifier.isMuted('tab-a'), isFalse);
    expect(notifier.isMuted('tab-b'), isTrue);
  });
}
