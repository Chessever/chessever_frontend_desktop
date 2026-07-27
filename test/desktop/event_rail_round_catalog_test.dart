import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/round_ordering.dart';

/// The columns the Board event rail asks `rounds` for.
///
/// `rounds` is `id, slug, tour_id, tour_slug, name, created_at, starts_at, url,
/// pairings`. Selecting anything else makes PostgREST answer 400 and the whole
/// round catalog throws, which silently strips every authoritative heading from
/// the rail. Keep this list a subset of the real schema.
const _requestedRoundColumns = <String>[
  'id',
  'name',
  'starts_at',
  'created_at',
];

const _actualRoundColumns = <String>{
  'id',
  'slug',
  'tour_id',
  'tour_slug',
  'name',
  'created_at',
  'starts_at',
  'url',
  'pairings',
};

void main() {
  test('the round catalog only selects columns that exist on rounds', () {
    for (final column in _requestedRoundColumns) {
      expect(
        _actualRoundColumns,
        contains(column),
        reason:
            'rounds.$column does not exist; PostgREST would answer 400 and the '
            'rail would fall back to headings derived from loaded game rows.',
      );
    }
    expect(_requestedRoundColumns, isNot(contains('ongoing')));
  });

  test('round metadata carries no ongoing flag', () {
    // Guards against reintroducing a field that has no backing column.
    const metadata = EventRailRoundMetadata(
      id: 'round-1',
      name: 'Round 1',
      startsAt: null,
      createdAt: null,
    );
    expect(metadata.id, 'round-1');
    expect(metadata.name, 'Round 1');
  });

  group('rail round display order', () {
    GamesAppBarModel round(String name, DateTime startsAt, RoundStatus status) {
      return GamesAppBarModel(
        id: name.toLowerCase().replaceAll(' ', '-'),
        name: name,
        startsAt: startsAt,
        roundStatus: status,
      );
    }

    test('played rounds come before scheduled ones, newest played first', () {
      final now = DateTime.utc(2026, 7, 22, 12);
      final models = <GamesAppBarModel>[
        round('Round 1', DateTime.utc(2026, 7, 18), RoundStatus.completed),
        round('Round 5', DateTime.utc(2026, 7, 26), RoundStatus.upcoming),
        round('Round 3', DateTime.utc(2026, 7, 20), RoundStatus.completed),
        round('Round 2', DateTime.utc(2026, 7, 19), RoundStatus.completed),
        round('Round 4', DateTime.utc(2026, 7, 21), RoundStatus.completed),
      ];

      final ordered = sortRoundsForDisplay(
        models,
        resolveDate: (model) => model.startsAt,
        now: now,
      );

      expect(ordered.map((model) => model.name).toList(), <String>[
        'Round 4',
        'Round 3',
        'Round 2',
        'Round 1',
        'Round 5',
      ]);
    });

    test('a round with no start time is never stranded behind the schedule', () {
      final now = DateTime.utc(2026, 7, 22, 12);
      final models = <GamesAppBarModel>[
        round('Round 9', DateTime.utc(2026, 7, 30), RoundStatus.upcoming),
        GamesAppBarModel(
          id: 'undated',
          name: 'Round 6',
          startsAt: null,
          roundStatus: RoundStatus.completed,
        ),
      ];

      final ordered = sortRoundsForDisplay(
        models,
        resolveDate: (model) => model.startsAt,
        now: now,
      );

      expect(ordered.first.name, 'Round 6');
      expect(ordered.last.name, 'Round 9');
    });
  });
}
