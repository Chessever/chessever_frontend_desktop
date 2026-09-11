import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_quota_queue.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';

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

  test('denied explorer refresh does not even read the repository', () async {
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        gamebaseExplorerProvider.overrideWith(
          (ref) => GamebaseExplorerNotifier(ref, accessCheck: (_, __) => false),
        ),
        gamebaseRepositoryProvider.overrideWith((_) {
          reads++;
          throw StateError('Forbidden fetch');
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(gamebaseExplorerProvider.notifier).refresh();
    expect(reads, 0);
  });

  test(
    'server-confirmed billing grace is not mistaken for term expiration',
    () {
      final now = DateTime.utc(2026, 9, 10);
      final grace = SubscriptionState(
        isSubscribed: true,
        inBillingGracePeriod: true,
        expirationDate: now.subtract(const Duration(days: 1)),
      );
      expect(desktopPremiumAccess(grace, now: now), DesktopAccess.allowed);
      expect(
        desktopPremiumAccess(grace.copyWith(error: 'offline'), now: now),
        DesktopAccess.unavailable,
      );
      expect(
        desktopPremiumAccess(grace.copyWith(isSubscribed: false), now: now),
        DesktopAccess.premiumRequired,
      );
      expect(
        desktopCanContinuePremiumWork(
          grace.copyWith(isLoading: true),
          now: now,
        ),
        isTrue,
      );
      expect(
        desktopPremiumAccess(grace.copyWith(isLoading: true), now: now),
        DesktopAccess.checking,
      );
    },
  );
}
