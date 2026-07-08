import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';

/// resqlite opens one writer per database file and uses `BEGIN IMMEDIATE`, so
/// the app's several connections to the same cache file (shared connection +
/// import isolate + tree-rebuild isolate) must never issue overlapping write
/// transactions or the loser throws `SQLITE_BUSY` ("database is locked").
///
/// Every writer is routed through the process-global write lock. These tests
/// assert that lock actually serializes — at most one write body runs at a
/// time and ordering/throughput are preserved — without spinning up isolates.
void main() {
  test('overlapping writes never run concurrently', () async {
    var active = 0;
    var maxConcurrent = 0;

    Future<void> op(int holdMicros) {
      return LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
        active++;
        maxConcurrent = math.max(maxConcurrent, active);
        // Yield the event loop several times while "holding" the lock so a
        // broken (non-serializing) implementation would interleave here.
        for (var i = 0; i < holdMicros; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        active--;
      });
    }

    await Future.wait(<Future<void>>[op(5), op(5), op(5), op(5), op(5)]);

    expect(maxConcurrent, 1, reason: 'writes must be fully serialized');
    expect(active, 0);
  });

  test('a failing write does not wedge the queue for later writes', () async {
    // A thrown write must release the lock so the next writer still runs —
    // otherwise one failed import would permanently freeze the local cache.
    final failing = LocalChessDatabaseRepository.debugRunWriteSerialized(
      () async => throw StateError('boom'),
    );
    await expectLater(failing, throwsA(isA<StateError>()));

    final result = await LocalChessDatabaseRepository.debugRunWriteSerialized(
      () async => 42,
    );
    expect(result, 42);
  });

  test('serialized writes preserve submission order', () async {
    final order = <int>[];
    final futures = <Future<void>>[];
    for (var i = 0; i < 8; i++) {
      final n = i;
      futures.add(
        LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
          await Future<void>.delayed(Duration.zero);
          order.add(n);
        }),
      );
    }
    await Future.wait(futures);
    expect(order, <int>[0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('queued writes can perform nested open-time writes inline', () async {
    final order = <String>[];

    await LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
      order.add('outer');
      await LocalChessDatabaseRepository.debugRunWriteSerialized(() async {
        order.add('inner');
      });
      order.add('done');
    }).timeout(const Duration(seconds: 1));

    expect(order, <String>['outer', 'inner', 'done']);
  });
}
