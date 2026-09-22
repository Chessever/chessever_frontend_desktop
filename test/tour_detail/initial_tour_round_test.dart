import 'package:chessever/repository/supabase/round/round.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/initial_tour_round.dart';
import 'package:flutter_test/flutter_test.dart';

Round _round(String id, int? day) => Round(
  id: id,
  slug: id,
  tourId: 'open',
  tourSlug: 'open',
  name: id,
  createdAt: DateTime.utc(2026, 9, 1),
  startsAt: day == null ? null : DateTime.utc(2026, 9, day),
  url: '',
);

void main() {
  final now = DateTime.utc(2026, 9, 19, 12);
  final rounds = [_round('r1', 17), _round('r2', 19), _round('r3', 20)];

  test('current started round wins over prepublished future rounds', () {
    expect(initialTourRoundId(rounds: rounds, now: now), 'r2');
  });

  test('explicit round navigation wins over current and live rounds', () {
    expect(
      initialTourRoundId(
        rounds: rounds,
        now: now,
        requestedRoundId: 'r1',
        liveRoundIds: const ['r2'],
      ),
      'r1',
    );
  });

  test('foreign live round cannot escape the selected tournament', () {
    expect(
      initialTourRoundId(
        rounds: rounds,
        now: now,
        liveRoundIds: const ['women-r3'],
      ),
      'r2',
    );
  });

  test('upcoming tournament opens its first round', () {
    expect(
      initialTourRoundId(rounds: rounds, now: DateTime.utc(2026, 9, 1)),
      'r1',
    );
  });
}
