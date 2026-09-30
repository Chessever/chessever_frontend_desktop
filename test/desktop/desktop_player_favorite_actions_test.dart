import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/services/desktop_player_favorite_actions.dart';
import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:flutter_test/flutter_test.dart';

FreemiumQuotaResult quota(int used) => FreemiumQuotaResult(
  kind: FreemiumQuotaKind.favoritePlayers,
  outcome:
      used < 3
          ? FreemiumQuotaOutcome.allowed
          : FreemiumQuotaOutcome.quotaExceeded,
  reason: used < 3 ? 'within_limit' : 'quota_exceeded',
  requested: 1,
  used: used,
  limit: 3,
  source: FreemiumQuotaSource.clientFallback,
);

void main() {
  test(
    'fresh count three denies fourth and presents capacity once, no write',
    () async {
      var writes = 0;
      final shown = <FreemiumQuotaResult>[];
      final accepted = await runDesktopFavoriteMutation(
        adding: true,
        check: () async => quota(3),
        mutate: () async {
          writes++;
        },
        showLimit: (q) async {
          shown.add(q);
        },
        showRetry: () => fail('not an outage'),
        isCurrent: () => true,
      );
      expect(accepted, isFalse);
      expect(writes, 0);
      expect(shown.single.used, 3);
      expect(shown.single.limit, 3);
    },
  );

  test('third waits for authoritative count before committing', () async {
    final pending = Completer<FreemiumQuotaResult>();
    var writes = 0;
    final op = runDesktopFavoriteMutation(
      adding: true,
      check: () => pending.future,
      mutate: () async {
        writes++;
      },
      showLimit: (_) async => fail('within allowance'),
      showRetry: () => fail('not an outage'),
      isCurrent: () => true,
    );
    expect(writes, 0);
    pending.complete(quota(2));
    expect(await op, isTrue);
    expect(writes, 1);
  });

  test('unknown count shows retry, not upsell or insert', () async {
    var retry = 0;
    expect(
      await runDesktopFavoriteMutation(
        adding: true,
        check:
            () async => FreemiumQuotaResult.unavailable(
              FreemiumQuotaKind.favoritePlayers,
              1,
              reason: 'request_failed',
            ),
        mutate: () async => fail('unknown cannot write'),
        showLimit: (_) async => fail('outage is not premium denial'),
        showRetry: () {
          retry++;
        },
        isCurrent: () => true,
      ),
      isFalse,
    );
    expect(retry, 1);
  });

  test('account change during count drops denial and mutation', () async {
    var current = true;
    expect(
      await runDesktopFavoriteMutation(
        adding: true,
        check: () async {
          current = false;
          return quota(3);
        },
        mutate: () async => fail('stale account'),
        showLimit: (_) async => fail('stale dialog'),
        showRetry: () => fail('stale toast'),
        isCurrent: () => current,
      ),
      isFalse,
    );
  });

  test('write-boundary rejection is presented instead of swallowed', () async {
    var shown = 0;
    expect(
      await runDesktopFavoriteMutation(
        adding: true,
        check: () async => quota(2),
        mutate: () async => throw const FavoriteLimitExceededException(3),
        showLimit: (q) async {
          shown++;
          expect(q.limit, 3);
        },
        showRetry: () => fail('quota needs paywall'),
        isCurrent: () => true,
      ),
      isFalse,
    );
    expect(shown, 1);
  });

  test('removal never spends a slot', () async {
    expect(
      await runDesktopFavoriteMutation(
        adding: false,
        check: () async => fail('removal never checks quota'),
        mutate: () async {},
        showLimit: (_) async => fail('removal is free'),
        showRetry: () => fail('no error'),
        isCurrent: () => true,
      ),
      isTrue,
    );
  });

  test('Favorites and Countrymen lists use the desktop admission action', () {
    for (final path in [
      'lib/desktop/panes/favorites_pane.dart',
      'lib/desktop/panes/countrymen_pane.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('setDesktopPlayerFavorite('));
      expect(source, isNot(contains('.toggleFavorite(player);')));
    }
  });
}
