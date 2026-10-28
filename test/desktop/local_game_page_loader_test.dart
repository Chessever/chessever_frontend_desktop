import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/state/local_game_page_loader.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';

LocalChessGameQueryPage page(int n) => LocalChessGameQueryPage(
  games: const [],
  totalCount: 0,
  pageNumber: n,
  pageSize: 200,
);
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'rapid jumps coalesce queued demand and drain idle destination',
    () async {
      final requests = <int>[];
      final pending = <int, Completer<LocalChessGameQueryPage?>>{};
      final loader = LocalGamePageLoader((p) {
        requests.add(p);
        return pending
            .putIfAbsent(p, Completer<LocalChessGameQueryPage?>.new)
            .future;
      });
      loader.demand([1, 2]);
      loader.demand([6, 7]);
      loader.demand([9, 10]);
      loader.demand([9, 10]);
      expect(requests, [1, 2]);
      pending[2]!.complete(page(2));
      await tick();
      expect(requests, [1, 2, 9]);
      pending[1]!.complete(page(1));
      await tick();
      expect(requests, [1, 2, 9, 10]);
      pending[10]!.complete(page(10));
      pending[9]!.complete(page(9));
      await tick();
      expect(loader.pages.keys, containsAll([9, 10]));
      expect(loader.isLoading, isFalse);
      loader.dispose();
    },
  );

  test('failed page is explicit, no automatic loop, retry recovers', () async {
    var attempts = 0;
    final loader = LocalGamePageLoader((p) async {
      if (++attempts == 1) throw StateError('read failed');
      return page(p);
    });
    loader.demand([10]);
    await tick();
    expect(loader.errors.keys, [10]);
    loader.demand([10]);
    loader.request(10);
    await tick();
    expect(attempts, 1);
    loader.retry(10);
    await tick();
    expect(loader.errors, isEmpty);
    expect(loader.pages.keys, [10]);
    expect(attempts, 2);
    loader.dispose();
  });

  test(
    'null and incomplete successful responses are retryable errors',
    () async {
      final loader = LocalGamePageLoader(
        (p) async =>
            p == 0
                ? null
                : LocalChessGameQueryPage(
                  games: const [],
                  totalCount: 2691,
                  pageNumber: p,
                  pageSize: 200,
                ),
      );
      loader.demand([0, 10]);
      await tick();
      expect(loader.errors.keys, containsAll([0, 10]));
      expect(loader.pages, isEmpty);
      expect(loader.isLoading, isFalse);
      loader.dispose();
    },
  );

  test(
    'disposed sort generation cannot publish or drain queued requests',
    () async {
      final pending = Completer<LocalChessGameQueryPage?>();
      var calls = 0;
      var notifications = 0;
      final old = LocalGamePageLoader((p) {
        calls++;
        return pending.future;
      });
      old.addListener(() => notifications++);
      old.demand([0, 1, 2]);
      old.dispose();
      final current = LocalGamePageLoader((p) async => page(p));
      current.demand([0]);
      await tick();
      pending.completeError(StateError('obsolete failure'));
      await tick();
      expect(notifications, 0);
      expect(calls, 2);
      expect(current.pages.keys, [0]);
      expect(current.errors, isEmpty);
      current.dispose();
    },
  );

  test(
    'cache eviction protects destination from obsolete completion',
    () async {
      final loader = LocalGamePageLoader((p) async => page(p), cacheLimit: 2);
      for (var i = 0; i < 30; i++) {
        loader.demand([i]);
        await tick();
      }
      expect(loader.pages.length, 2);
      expect(loader.pages.keys, contains(29));
      loader.demand([0]);
      await tick();
      expect(loader.pages.keys, contains(0));
      expect(loader.pages.length, 2);
      loader.dispose();
    },
  );
}
