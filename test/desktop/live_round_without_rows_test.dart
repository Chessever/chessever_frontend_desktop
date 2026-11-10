import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';

GamesAppBarModel _round({
  required String id,
  required String name,
  required RoundStatus status,
}) {
  return GamesAppBarModel(
    id: id,
    name: name,
    startsAt: DateTime.now().subtract(const Duration(minutes: 5)),
    roundStatus: status,
  );
}

void main() {
  test('a live round with no fetched rows still gets a Games-tab heading', () {
    final rounds = <GamesAppBarModel>[
      _round(id: 'round-7', name: 'Round 7', status: RoundStatus.completed),
      _round(id: 'round-8', name: 'Round 8', status: RoundStatus.live),
    ];

    final empty = liveRoundsWithoutRows(
      rounds: rounds,
      gamesByRound: const <String, List<GamesTourModel>>{},
      upcomingPairingRoundIds: const <String>{},
      sourceRoundIds: const <String>{'round-7'},
      isMultiStageKnockout: false,
    );

    expect(empty.map((round) => round.id), <String>['round-8']);
  });

  test('a clock-only started round without rows is not invented', () {
    final rounds = <GamesAppBarModel>[
      _round(id: 'round-8', name: 'Round 8', status: RoundStatus.ongoing),
    ];

    final empty = liveRoundsWithoutRows(
      rounds: rounds,
      gamesByRound: const <String, List<GamesTourModel>>{},
      upcomingPairingRoundIds: const <String>{},
      sourceRoundIds: const <String>{},
      isMultiStageKnockout: false,
    );

    expect(empty, isEmpty);
  });

  test('multi-stage knockouts keep their synthetic stage representation', () {
    final rounds = <GamesAppBarModel>[
      _round(id: 'round-8', name: 'Round 8', status: RoundStatus.live),
    ];

    final empty = liveRoundsWithoutRows(
      rounds: rounds,
      gamesByRound: const <String, List<GamesTourModel>>{},
      upcomingPairingRoundIds: const <String>{},
      sourceRoundIds: const <String>{},
      isMultiStageKnockout: true,
    );

    expect(empty, isEmpty);
  });
}
