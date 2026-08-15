import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scroll stage membership delegates to the shared stage resolver', () {
    final source =
        File(
          'lib/screens/tour_detail/games_tour/providers/'
          'games_tour_scroll_provider.dart',
        ).readAsStringSync();

    expect(
      source,
      contains('itemsForTournamentDisplayRound<GamesTourModel>'),
      reason:
          'scroll indexing must share the same source-round membership resolver '
          'as rendering and app-bar counts',
    );
    expect(
      source,
      isNot(contains('knockoutTournamentStateProvider(stageTourId)')),
      reason:
          'synthetic stage suffixes are not necessarily tour ids and must never '
          'start per-stage classifier requests',
    );
  });
}
