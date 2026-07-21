import 'package:chessever/desktop/widgets/desktop_event_countdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('countdown keeps hours and minutes compact', () {
    expect(
      desktopEventCountdownText(
        const Duration(hours: 3, minutes: 7, seconds: 42),
      ),
      '3h 7m',
    );
  });

  test('countdown shows seconds below one hour', () {
    expect(
      desktopEventCountdownText(const Duration(minutes: 4, seconds: 9)),
      '4m 9s',
    );
    expect(desktopEventCountdownText(const Duration(seconds: 8)), '8s');
  });

  test('round label counts down inside twenty-four hours', () {
    final now = DateTime(2026, 7, 19, 12);

    expect(
      desktopRoundStartLabel(
        roundName: 'Round 5',
        startsAt: now.add(const Duration(hours: 2, minutes: 30)),
        now: now,
      ),
      'Round 5 · starts in 2h 30m',
    );
  });

  test('round label uses scheduled time outside the countdown window', () {
    final now = DateTime(2026, 7, 19, 12);

    expect(
      desktopRoundStartLabel(
        roundName: 'Round 6',
        startsAt: DateTime(2026, 7, 21, 14, 5),
        now: now,
      ),
      'Round 6 · starts Tue Jul 21, 14:05',
    );
  });

  test('elapsed rounds do not render a label', () {
    final now = DateTime(2026, 7, 19, 12);

    expect(
      desktopRoundStartLabel(
        roundName: 'Round 4',
        startsAt: now.subtract(const Duration(seconds: 1)),
        now: now,
      ),
      isEmpty,
    );
  });
}
