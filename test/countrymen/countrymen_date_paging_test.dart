import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_combined_games_provider.dart';
import 'package:country_picker/country_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  final us = CountryService().findByCode('US')!;
  final day1 = DateTime(2026, 9, 14);
  final day2 = DateTime(2026, 9, 13);
  final day3 = DateTime(2026, 9, 12);
  final day4 = DateTime(2026, 9, 11);

  test(
    'pages dates with a newest-day cursor instead of a 30-date DISTINCT',
    () async {
      final repo = _FakeGameRepository(catalog: [day1, day2, day3, day4]);
      final countryProvider = StateProvider<Country>((ref) => us);
      final container = ProviderContainer(
        overrides: [
          gameRepositoryProvider.overrideWithValue(repo),
          effectiveCountryProvider.overrideWith(
            (ref) => AsyncValue.data(ref.watch(countryProvider)),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(countrymenCombinedGamesProvider, (_, __) {});

      await _waitUntil(
        () => container.read(countrymenCombinedGamesProvider).games.length == 3,
      );

      expect(repo.dateCalls, hasLength(1));
      expect(repo.dateCalls.single.limit, 3);
      expect(repo.dateCalls.single.before, isNull);
      expect(repo.dateCalls.single.offset, 0);
      expect(
        container
            .read(countrymenCombinedGamesProvider)
            .games
            .map((g) => g.gameId),
        ['USA-14', 'USA-13', 'USA-12'],
      );

      await container
          .read(countrymenCombinedGamesProvider.notifier)
          .loadMoreGames();
      await _waitUntil(
        () => container.read(countrymenCombinedGamesProvider).games.length == 4,
      );

      expect(repo.dateCalls, hasLength(2));
      expect(repo.dateCalls.last.limit, 3);
      expect(repo.dateCalls.last.before, day3);
      expect(
        container
            .read(countrymenCombinedGamesProvider)
            .games
            .map((g) => g.gameId),
        ['USA-14', 'USA-13', 'USA-12', 'USA-11'],
      );
    },
  );
}

class _DateCall {
  const _DateCall({
    required this.countryCode,
    required this.limit,
    required this.offset,
    required this.before,
  });

  final String countryCode;
  final int limit;
  final int offset;
  final DateTime? before;
}

class _FakeGameRepository implements GameRepository {
  _FakeGameRepository({required this.catalog});

  final List<DateTime> catalog;
  final List<_DateCall> dateCalls = [];

  @override
  Future<List<DateTime>> getDistinctDatesForCountry({
    required String countryCode,
    int minElo = 2000,
    int limit = 30,
    int offset = 0,
    DateTime? before,
  }) async {
    dateCalls.add(
      _DateCall(
        countryCode: countryCode,
        limit: limit,
        offset: offset,
        before: before,
      ),
    );
    Iterable<DateTime> remaining = catalog;
    if (before != null) {
      final cursor = DateTime(before.year, before.month, before.day);
      remaining = remaining.where((day) => day.isBefore(cursor));
    }
    return remaining.skip(offset).take(limit).toList();
  }

  @override
  Future<List<Games>> getGamesByCountryAndDate({
    required String countryCode,
    required DateTime date,
    int minElo = 2000,
    String? eco,
  }) async {
    return [_game(countryCode, date)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Games _game(String fed, DateTime day) {
  return Games(
    id: '$fed-${day.day}',
    roundId: 'round-1',
    roundSlug: 'round-1',
    tourId: 'tour-1',
    tourSlug: 'Test Event',
    status: '1-0',
    lastMove: 'e4',
    dateStart: day,
    lastMoveTime: day,
    gameDay: day,
    players: [
      Player(
        name: 'White $fed',
        title: 'GM',
        rating: 2700,
        fideId: 1,
        fed: fed,
        clock: 0,
        team: '',
      ),
      Player(
        name: 'Black $fed',
        title: 'GM',
        rating: 2650,
        fideId: 2,
        fed: fed,
        clock: 0,
        team: '',
      ),
    ],
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not met before timeout.');
}
