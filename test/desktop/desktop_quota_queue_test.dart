import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/auth/desktop_quota_queue.dart';

void main() {
  test(
    'queued quota writes release successors after an earlier failure',
    () async {
      final queue = DesktopQuotaQueue();
      final release = Completer<void>();
      final started = <int>[];
      final first = queue.run<void>(() async {
        started.add(1);
        await release.future;
        throw StateError('rejected write');
      });
      final failure = expectLater(first, throwsStateError);
      final second = queue.run<int>(() async {
        started.add(2);
        return 2;
      });
      final third = queue.run<int>(() async {
        started.add(3);
        return 3;
      });
      await Future<void>.delayed(Duration.zero);
      expect(started, [1]);
      release.complete();
      await failure;
      expect(await second, 2);
      expect(await third, 3);
      expect(started, [1, 2, 3]);
    },
  );

  test('the slot is released when the action throws before awaiting',
      () async {
    final queue = DesktopQuotaQueue();
    await expectLater(
      queue.run<void>(() => throw ArgumentError('count failed')),
      throwsArgumentError,
    );
    expect(await queue.run<String>(() async => 'next'), 'next');
  });

  test('admission is strictly FIFO, so a COUNT never reads a stale total',
      () async {
    final queue = DesktopQuotaQueue();
    var saved = 0;
    final seen = <int>[];
    Future<void> admit() => queue.run<void>(() async {
      final count = saved;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      seen.add(count);
      saved = count + 1;
    });
    await Future.wait([admit(), admit(), admit()]);
    expect(seen, [0, 1, 2]);
    expect(saved, 3);
  });
}
