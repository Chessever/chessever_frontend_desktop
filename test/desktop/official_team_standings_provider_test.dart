import 'dart:async';

import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/standings/official_team_standings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('refreshes the exact tour and accepts a removed snapshot', (
    tester,
  ) async {
    var calls = 0;
    final ids = <String>[];
    final container = ProviderContainer(
      overrides: [
        officialTeamInfoRefreshIntervalProvider.overrideWithValue(
          const Duration(seconds: 1),
        ),
        officialTeamInfoLoaderProvider.overrideWithValue((id) async {
          ids.add(id);
          calls++;
          return calls == 1
              ? const TourInfo(officialTeamStandings: {'round': 1})
              : const TourInfo();
        }),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      officialTeamInfoProvider('  board-tour  '),
      (_, _) {},
    );
    await tester.pump();
    expect(
      container
          .read(officialTeamInfoProvider('  board-tour  '))
          .requireValue
          ?.officialTeamStandings?['round'],
      1,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
      container
          .read(officialTeamInfoProvider('  board-tour  '))
          .requireValue
          ?.officialTeamStandings,
      isNull,
    );
    expect(ids, ['board-tour', 'board-tour']);
    subscription.close();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 2);
  });

  testWidgets('does not overlap a slow fetch or emit after disposal', (
    tester,
  ) async {
    final pending = Completer<TourInfo?>();
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        officialTeamInfoRefreshIntervalProvider.overrideWithValue(
          const Duration(seconds: 1),
        ),
        officialTeamInfoLoaderProvider.overrideWithValue((id) {
          calls++;
          return pending.future;
        }),
      ],
    );
    final subscription = container.listen(
      officialTeamInfoProvider('slow-tour'),
      (_, _) {},
    );
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    subscription.close();
    container.dispose();
    pending.complete(const TourInfo());
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
