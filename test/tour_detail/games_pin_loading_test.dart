import 'dart:async';

import 'package:chessever/screens/tour_detail/games_tour/providers/games_pin_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'pin reload burst is serialized into one load and one catch-up',
    () async {
      final coordinator = GamesPinLoadCoordinator();
      final firstLoad = Completer<void>();
      final catchUpLoad = Completer<void>();
      var calls = 0;
      var activeLoads = 0;
      var maxActiveLoads = 0;

      Future<void> load() async {
        calls++;
        activeLoads++;
        if (activeLoads > maxActiveLoads) maxActiveLoads = activeLoads;
        try {
          if (calls == 1) {
            await firstLoad.future;
          } else {
            await catchUpLoad.future;
          }
        } finally {
          activeLoads--;
        }
      }

      final requests = <Future<void>>[
        for (var i = 0; i < 21; i++) coordinator.schedule(load),
      ];
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(maxActiveLoads, 1);

      firstLoad.complete();
      await _waitUntil(() => calls == 2);

      expect(calls, 2);
      expect(maxActiveLoads, 1);

      catchUpLoad.complete();
      await Future.wait(requests);

      expect(calls, 2);
      expect(maxActiveLoads, 1);
    },
  );

  test(
    'queued pin catch-up still runs after a transient first failure',
    () async {
      final coordinator = GamesPinLoadCoordinator();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var calls = 0;

      Future<void> load() async {
        calls++;
        if (calls == 1) {
          firstStarted.complete();
          await releaseFirst.future;
          throw StateError('transient pin storage failure');
        }
      }

      final firstRequest = coordinator.schedule(load);
      await firstStarted.future;
      final catchUpRequest = coordinator.schedule(load);
      releaseFirst.complete();

      await Future.wait(<Future<void>>[firstRequest, catchUpRequest]);
      expect(calls, 2);
    },
  );

  test('multi-stage auto-pins wait until every stage load settles', () {
    final stageIds = <String>[for (var i = 1; i <= 21; i++) 'stage-$i'];
    final settled = stageIds.toSet()..remove('stage-21');

    expect(
      tournamentStageLoadsSettled(
        tourIds: stageIds,
        hasSettled: settled.contains,
      ),
      isFalse,
    );

    settled.add('stage-21');
    expect(
      tournamentStageLoadsSettled(
        tourIds: stageIds,
        hasSettled: settled.contains,
      ),
      isTrue,
    );
  });

  test('a final empty or failed stage still requests pin reconciliation', () {
    for (final nextIds in <List<String>>[const <String>[], const <String>[]]) {
      expect(
        tournamentStageUpdateNeedsPinRefresh(
          previousSettled: false,
          nextSettled: true,
          previousGameIds: const <String>[],
          nextGameIds: nextIds,
        ),
        isTrue,
      );
    }

    expect(
      tournamentStageUpdateNeedsPinRefresh(
        previousSettled: true,
        nextSettled: true,
        previousGameIds: const <String>[],
        nextGameIds: const <String>[],
      ),
      isFalse,
      reason: 'an unchanged settled stage must not restart the scan',
    );
  });

  test(
    'a stuck sibling permits one primary-stage scan plus the final scan',
    () {
      expect(
        tournamentStageLoadsReadyForPinRefresh(
          primarySettled: true,
          allSettled: false,
          partialRefreshAlreadyScheduled: false,
        ),
        isTrue,
      );
      expect(
        tournamentStageLoadsReadyForPinRefresh(
          primarySettled: true,
          allSettled: false,
          partialRefreshAlreadyScheduled: true,
        ),
        isFalse,
      );
      expect(
        tournamentStageLoadsReadyForPinRefresh(
          primarySettled: true,
          allSettled: true,
          partialRefreshAlreadyScheduled: true,
        ),
        isTrue,
      );
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 20; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition was not reached');
}
