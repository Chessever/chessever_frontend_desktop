import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_stage_id.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/round_ordering.dart';
import 'package:flutter_test/flutter_test.dart';

GamesAppBarModel _round({
  required String id,
  required String name,
  required DateTime? startsAt,
  required RoundStatus status,
}) {
  return GamesAppBarModel(
    id: id,
    name: name,
    startsAt: startsAt,
    roundStatus: status,
  );
}

List<String> _ids(List<GamesAppBarModel> rounds) =>
    rounds.map((round) => round.id).toList(growable: false);

void main() {
  group('sortRoundsForDisplay', () {
    test('keeps started rounds first and both sections descending', () {
      final now = DateTime(2026, 5, 27, 18);
      final rounds = [
        _round(
          id: 'r1',
          name: 'Round 1',
          startsAt: DateTime(2026, 5, 25, 18),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r2',
          name: 'Round 2',
          startsAt: DateTime(2026, 5, 26, 18),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r3',
          name: 'Round 3',
          startsAt: DateTime(2026, 5, 27, 18),
          status: RoundStatus.live,
        ),
        _round(
          id: 'r4',
          name: 'Round 4',
          startsAt: DateTime(2026, 5, 28, 18),
          status: RoundStatus.upcoming,
        ),
        _round(
          id: 'r5',
          name: 'Round 5',
          startsAt: DateTime(2026, 5, 29, 18),
          status: RoundStatus.upcoming,
        ),
        _round(
          id: 'r6',
          name: 'Round 6',
          startsAt: DateTime(2026, 5, 30, 18),
          status: RoundStatus.upcoming,
        ),
      ];

      final sorted = sortRoundsForDisplay(
        rounds,
        resolveDate: (round) => round.startsAt,
        now: now,
      );

      expect(_ids(sorted), ['r3', 'r2', 'r1', 'r6', 'r5', 'r4']);
    });

    test('keeps all future rounds in descending order', () {
      final now = DateTime(2026, 3, 29, 10);
      final rounds = [
        _round(
          id: 'r3',
          name: 'Round 3',
          startsAt: now.add(const Duration(days: 2)),
          status: RoundStatus.upcoming,
        ),
        _round(
          id: 'r1',
          name: 'Round 1',
          startsAt: now.add(const Duration(hours: 6)),
          status: RoundStatus.upcoming,
        ),
        _round(
          id: 'r2',
          name: 'Round 2',
          startsAt: now.add(const Duration(days: 1)),
          status: RoundStatus.upcoming,
        ),
      ];

      final sorted = sortRoundsForDisplay(
        rounds,
        resolveDate: (round) => round.startsAt,
        now: now,
      );

      expect(_ids(sorted), ['r3', 'r2', 'r1']);
    });

    test(
      'promotes next round inside two hours when all started rounds finished',
      () {
        final now = DateTime(2026, 3, 30, 16);
        final rounds = [
          _round(
            id: 'r1',
            name: 'Round 1',
            startsAt: now.subtract(const Duration(hours: 4)),
            status: RoundStatus.completed,
          ),
          _round(
            id: 'r2',
            name: 'Round 2',
            startsAt: now.add(const Duration(minutes: 119)),
            status: RoundStatus.upcoming,
          ),
          _round(
            id: 'r3',
            name: 'Round 3',
            startsAt: now.add(const Duration(days: 1)),
            status: RoundStatus.upcoming,
          ),
          _round(
            id: 'r4',
            name: 'Round 4',
            startsAt: now.add(const Duration(days: 2)),
            status: RoundStatus.upcoming,
          ),
        ];

        final sorted = sortRoundsForDisplay(
          rounds,
          resolveDate: (round) => round.startsAt,
          isRoundFullyPlayed: (round) => round.id == 'r1',
          now: now,
        );

        expect(_ids(sorted), ['r2', 'r1', 'r4', 'r3']);
      },
    );

    test('does not promote while a started round is unfinished', () {
      final now = DateTime(2026, 3, 30, 16);
      final rounds = [
        _round(
          id: 'r1',
          name: 'Round 1',
          startsAt: now.subtract(const Duration(hours: 4)),
          status: RoundStatus.ongoing,
        ),
        _round(
          id: 'r2',
          name: 'Round 2',
          startsAt: now.add(const Duration(minutes: 30)),
          status: RoundStatus.upcoming,
        ),
        _round(
          id: 'r3',
          name: 'Round 3',
          startsAt: now.add(const Duration(days: 1)),
          status: RoundStatus.upcoming,
        ),
      ];

      final sorted = sortRoundsForDisplay(
        rounds,
        resolveDate: (round) => round.startsAt,
        isRoundFullyPlayed: (_) => false,
        now: now,
      );

      expect(_ids(sorted), ['r1', 'r3', 'r2']);
    });

    test('keeps previously started rounds in reverse chronological order', () {
      final now = DateTime(2026, 3, 31, 16);
      final rounds = [
        _round(
          id: 'r1',
          name: 'Round 1',
          startsAt: now.subtract(const Duration(days: 2)),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r2',
          name: 'Round 2',
          startsAt: now.subtract(const Duration(days: 1)),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r3',
          name: 'Round 3',
          startsAt: now.add(const Duration(minutes: 121)),
          status: RoundStatus.upcoming,
        ),
        _round(
          id: 'r4',
          name: 'Round 4',
          startsAt: now.add(const Duration(days: 1)),
          status: RoundStatus.upcoming,
        ),
      ];

      final sorted = sortRoundsForDisplay(
        rounds,
        resolveDate: (round) => round.startsAt,
        now: now,
      );

      expect(_ids(sorted), ['r2', 'r1', 'r4', 'r3']);
    });

    test('ends with latest round first and all prior rounds descending', () {
      final now = DateTime(2026, 4, 12, 16);
      final rounds = [
        for (var i = 1; i <= 4; i++)
          _round(
            id: 'r$i',
            name: 'Round $i',
            startsAt: DateTime(2026, 4, 8 + i, 12),
            status: RoundStatus.completed,
          ),
      ];

      final sorted = sortRoundsForDisplay(
        rounds,
        resolveDate: (round) => round.startsAt,
        now: now,
      );

      expect(_ids(sorted), ['r4', 'r3', 'r2', 'r1']);
    });

    test('orders started generic rounds by round number when dates jump', () {
      final now = DateTime(2026, 4, 24, 16);
      final rounds = [
        _round(
          id: 'r10',
          name: 'Round 10',
          startsAt: DateTime(2026, 3, 22, 9, 15),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r11',
          name: 'Round 11',
          startsAt: DateTime(2026, 1, 10, 13, 15),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r12',
          name: 'Round 12',
          startsAt: DateTime(2026, 1, 11, 9, 15),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r13',
          name: 'Round 13',
          startsAt: DateTime(2026, 4, 24, 14, 15),
          status: RoundStatus.live,
        ),
      ];

      final sorted = sortRoundsForDisplay(
        rounds,
        resolveDate: (round) => round.startsAt,
        now: now,
      );

      expect(_ids(sorted), ['r13', 'r12', 'r11', 'r10']);
    });
  });

  group('pickPreferredRoundForSelection', () {
    test(
      'selects next round inside two hours when latest round is fully played',
      () {
        final now = DateTime(2026, 3, 30, 16);
        final rounds = [
          _round(
            id: 'r1',
            name: 'Round 1',
            startsAt: now.subtract(const Duration(hours: 4)),
            status: RoundStatus.completed,
          ),
          _round(
            id: 'r2',
            name: 'Round 2',
            startsAt: now.add(const Duration(minutes: 119)),
            status: RoundStatus.upcoming,
          ),
          _round(
            id: 'r3',
            name: 'Round 3',
            startsAt: now.add(const Duration(days: 1)),
            status: RoundStatus.upcoming,
          ),
        ];

        final selected = pickPreferredRoundForSelection(
          rounds,
          resolveDate: (round) => round.startsAt,
          hasGames: (_) => true,
          isRoundFullyPlayed: (round) => round.id == 'r1',
          now: now,
        );

        expect(selected?.id, 'r2');
      },
    );

    test('returns null when hasGames filters out every round', () {
      final now = DateTime(2026, 3, 30, 16);
      final rounds = [
        _round(
          id: 'r1',
          name: 'Round 1',
          startsAt: now.subtract(const Duration(hours: 4)),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r2',
          name: 'Round 2',
          startsAt: now.add(const Duration(hours: 1)),
          status: RoundStatus.upcoming,
        ),
      ];

      final selected = pickPreferredRoundForSelection(
        rounds,
        resolveDate: (round) => round.startsAt,
        hasGames: (_) => false,
        now: now,
      );

      expect(selected, isNull);
    });

    test(
      'prefers the most recent live round when multiple live rounds exist',
      () {
        final now = DateTime(2026, 3, 30, 16);
        final rounds = [
          _round(
            id: 'r1',
            name: 'Round 1',
            startsAt: now.subtract(const Duration(hours: 3)),
            status: RoundStatus.live,
          ),
          _round(
            id: 'r2',
            name: 'Round 2',
            startsAt: now.subtract(const Duration(hours: 1)),
            status: RoundStatus.live,
          ),
          _round(
            id: 'r3',
            name: 'Round 3',
            startsAt: now.add(const Duration(hours: 2)),
            status: RoundStatus.upcoming,
          ),
        ];

        final selected = pickPreferredRoundForSelection(
          rounds,
          resolveDate: (round) => round.startsAt,
          hasGames: (_) => true,
          now: now,
        );

        expect(selected?.id, 'r2');
      },
    );

    test('prefers highest generic started round when round dates jump', () {
      final now = DateTime(2026, 4, 24, 16);
      final rounds = [
        _round(
          id: 'r10',
          name: 'Round 10',
          startsAt: DateTime(2026, 3, 22, 9, 15),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r11',
          name: 'Round 11',
          startsAt: DateTime(2026, 1, 10, 13, 15),
          status: RoundStatus.completed,
        ),
        _round(
          id: 'r12',
          name: 'Round 12',
          startsAt: DateTime(2026, 1, 11, 9, 15),
          status: RoundStatus.completed,
        ),
      ];

      final selected = pickPreferredRoundForSelection(
        rounds,
        resolveDate: (round) => round.startsAt,
        hasGames: (_) => true,
        now: now,
      );

      expect(selected?.id, 'r12');
    });
  });

  group('selectRoundIdAfterLiveRoundsChanged', () {
    test('switches from a valid stale selection to the live round', () {
      final now = DateTime(2026, 6, 21, 11);
      final rounds = [
        _round(
          id: 'future-final',
          name: 'Finals | Game 1',
          startsAt: now.add(const Duration(hours: 1)),
          status: RoundStatus.upcoming,
        ),
        _round(
          id: 'live-semi',
          name: 'Semi Final 1 & Duels for 5th place | Game 2',
          startsAt: now.subtract(const Duration(minutes: 15)),
          status: RoundStatus.live,
        ),
        _round(
          id: 'old-semi',
          name: 'Semi Final 1 & Duels for 5th place | Game 1',
          startsAt: now.subtract(const Duration(minutes: 45)),
          status: RoundStatus.completed,
        ),
      ];

      final selected = selectRoundIdAfterLiveRoundsChanged(
        models: rounds,
        currentSelectedId: 'old-semi',
        stickySelection: (id: 'old-semi', userSelected: false),
        hasGames: (roundId) => roundId != 'future-final',
        resolveDate: (round) => round.startsAt,
      );

      expect(selected, 'live-semi');
    });

    test('preserves a valid user-selected sticky round', () {
      final now = DateTime(2026, 6, 21, 11);
      final rounds = [
        _round(
          id: 'live-semi',
          name: 'Semi Final 1 & Duels for 5th place | Game 2',
          startsAt: now.subtract(const Duration(minutes: 15)),
          status: RoundStatus.live,
        ),
        _round(
          id: 'old-semi',
          name: 'Semi Final 1 & Duels for 5th place | Game 1',
          startsAt: now.subtract(const Duration(minutes: 45)),
          status: RoundStatus.completed,
        ),
      ];

      final selected = selectRoundIdAfterLiveRoundsChanged(
        models: rounds,
        currentSelectedId: 'old-semi',
        stickySelection: (id: 'old-semi', userSelected: true),
        hasGames: (_) => true,
        resolveDate: (round) => round.startsAt,
      );

      expect(selected, 'old-semi');
    });
  });

  group('roundSlugDerivedKnockoutStageId', () {
    test(
      'maps FIDE team knockout round slug to the app-bar synthetic stage id',
      () {
        final id = roundSlugDerivedKnockoutStageId(
          tourId: 'AbN0a0LQ',
          roundSlug: 'semi-final-1-duels-for-5th-place-game-2',
        );

        expect(
          id,
          'knockout-stage-AbN0a0LQ-semi-final-1-duels-for-5th-place-game-2',
        );
      },
    );

    test('maps legacy double-dash stage slugs to the stage id', () {
      final id = roundSlugDerivedKnockoutStageId(
        tourId: 'tour-1',
        roundSlug: 'quarter-finals--game-1',
      );

      expect(id, 'knockout-stage-tour-1-quarter-finals');
    });
  });
}
