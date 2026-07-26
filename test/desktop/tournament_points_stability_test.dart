import 'dart:async';

import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _OverlappingSnapshotNotifier extends PlayerTourScreenNotifier {
  static final builds = <Completer<PlayerTourStandingsSnapshot>>[];

  @override
  Future<PlayerTourStandingsSnapshot> build() {
    final completer = Completer<PlayerTourStandingsSnapshot>();
    builds.add(completer);
    return completer.future;
  }
}

class _EmptySnapshotNotifier extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async =>
      PlayerTourStandingsSnapshot.empty;
}

class _ConflictingIdentitySnapshotNotifier extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async =>
      const PlayerTourStandingsSnapshot(
        tourIds: {'stable-tour'},
        standings: [
          PlayerStandingModel(
            countryCode: 'USA',
            name: 'Same, Player',
            score: 2500,
            scoreChange: 0,
            matchScore: '9 / 9',
            fideId: 222,
          ),
        ],
      );
}

class _ControlledRosterRepository implements TourRepository {
  final calls = <Completer<List<TournamentPlayer>>>[];
  int activeRequests = 0;
  int maxActiveRequests = 0;

  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) {
    expect(tourId, 'stable-tour');
    final completer = Completer<List<TournamentPlayer>>();
    calls.add(completer);
    activeRequests += 1;
    if (activeRequests > maxActiveRequests) {
      maxActiveRequests = activeRequests;
    }
    return completer.future.whenComplete(() => activeRequests -= 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ConflictingIdentityRosterRepository implements TourRepository {
  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    expect(tourId, 'stable-tour');
    return [
      TournamentPlayer(
        federation: 'USA',
        name: 'Same Player',
        fideId: 111,
        played: 3,
        rating: 2400,
        score: 2,
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _CountingRosterRepository implements TourRepository {
  int calls = 0;

  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    expect(tourId, 'stable-tour');
    calls += 1;
    return const <TournamentPlayer>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test(
    'successful empty roster resolves as data instead of loading forever',
    () async {
      final repository = _CountingRosterRepository();
      final container = ProviderContainer(
        overrides: [
          tourRepositoryProvider.overrideWithValue(repository),
          playerTourStandingsSnapshotProvider.overrideWith(
            _EmptySnapshotNotifier.new,
          ),
          tournamentRosterRefreshIntervalProvider.overrideWithValue(
            const Duration(days: 1),
          ),
        ],
      );
      addTearDown(container.dispose);
      final provider = tournamentRosterStandingsProvider('stable-tour');
      final subscription = container.listen(
        provider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      for (var i = 0; i < 3; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(repository.calls, 1);
      expect(container.read(provider).valueOrNull, isEmpty);
    },
  );

  test(
    'authoritative empty refresh clears previously published roster rows',
    () async {
      final repository = _ControlledRosterRepository();
      final container = ProviderContainer(
        overrides: [
          tourRepositoryProvider.overrideWithValue(repository),
          playerTourStandingsSnapshotProvider.overrideWith(
            _EmptySnapshotNotifier.new,
          ),
          tournamentRosterRefreshIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 1),
          ),
        ],
      );
      addTearDown(container.dispose);
      final provider = tournamentRosterStandingsProvider('stable-tour');
      final subscription = container.listen(
        provider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);

      repository.calls.single.complete([
        TournamentPlayer(
          federation: 'USA',
          name: 'Stale Player',
          fideId: 1,
          played: 1,
          rating: 2400,
          score: 1,
        ),
      ]);
      for (var i = 0; i < 20 && repository.calls.length < 2; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(container.read(provider).valueOrNull?.single.name, 'Stale Player');

      repository.calls[1].complete(const <TournamentPlayer>[]);
      for (var i = 0; i < 3; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(container.read(provider).valueOrNull, isEmpty);
    },
  );

  test(
    'roster and live rows with conflicting FIDE IDs remain separate',
    () async {
      final container = ProviderContainer(
        overrides: [
          tourRepositoryProvider.overrideWithValue(
            _ConflictingIdentityRosterRepository(),
          ),
          playerTourStandingsSnapshotProvider.overrideWith(
            _ConflictingIdentitySnapshotNotifier.new,
          ),
          tournamentRosterRefreshIntervalProvider.overrideWithValue(
            const Duration(days: 1),
          ),
        ],
      );
      addTearDown(container.dispose);
      final provider = tournamentRosterStandingsProvider('stable-tour');
      final subscription = container.listen(
        provider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      for (var i = 0; i < 4; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      final standings = container.read(provider).valueOrNull;
      expect(standings, isNotNull);
      expect(
        standings!.map((standing) => standing.fideId).whereType<int>().toSet(),
        {111, 222},
      );
    },
  );

  test(
    'superseded standings build cannot retag the published snapshot',
    () async {
      _OverlappingSnapshotNotifier.builds.clear();
      final container = ProviderContainer(
        overrides: [
          playerTourStandingsSnapshotProvider.overrideWith(
            _OverlappingSnapshotNotifier.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        playerTourStandingsSnapshotProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);
      expect(_OverlappingSnapshotNotifier.builds, hasLength(1));

      container.invalidate(playerTourStandingsSnapshotProvider);
      await Future<void>.delayed(Duration.zero);
      expect(_OverlappingSnapshotNotifier.builds, hasLength(2));

      const eventB = PlayerTourStandingsSnapshot(
        tourIds: {'event-b'},
        standings: [
          PlayerStandingModel(
            countryCode: 'USA',
            name: 'Same Player',
            score: 2500,
            scoreChange: 0,
            matchScore: '4 / 5',
          ),
        ],
      );
      const eventA = PlayerTourStandingsSnapshot(
        tourIds: {'event-a'},
        standings: [
          PlayerStandingModel(
            countryCode: 'USA',
            name: 'Same Player',
            score: 2500,
            scoreChange: 0,
            matchScore: '2 / 5',
          ),
        ],
      );
      _OverlappingSnapshotNotifier.builds[1].complete(eventB);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(playerTourStandingsSnapshotProvider).valueOrNull,
        same(eventB),
      );

      _OverlappingSnapshotNotifier.builds[0].complete(eventA);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(playerTourStandingsSnapshotProvider).valueOrNull,
        same(eventB),
      );

      container.invalidate(playerTourStandingsSnapshotProvider);
      await Future<void>.delayed(Duration.zero);
      expect(_OverlappingSnapshotNotifier.builds, hasLength(3));
      expect(
        container.read(playerTourStandingsSnapshotProvider).valueOrNull,
        same(eventB),
      );
    },
  );

  test('roster refresh serializes an immediate cancel and resume', () async {
    final repository = _ControlledRosterRepository();
    final container = ProviderContainer(
      overrides: [
        tourRepositoryProvider.overrideWithValue(repository),
        playerTourStandingsSnapshotProvider.overrideWith(
          _EmptySnapshotNotifier.new,
        ),
        tournamentRosterRefreshIntervalProvider.overrideWithValue(
          const Duration(days: 1),
        ),
      ],
    );
    addTearDown(container.dispose);
    final provider = tournamentRosterStandingsProvider('stable-tour');
    final firstSubscription = container.listen(
      provider,
      (previous, next) {},
      fireImmediately: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(repository.calls, hasLength(1));

    firstSubscription.close();
    final resumedSubscription = container.listen(
      provider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(resumedSubscription.close);
    await Future<void>.delayed(Duration.zero);

    expect(repository.calls, hasLength(1));
    expect(repository.maxActiveRequests, 1);

    repository.calls.first.complete(const <TournamentPlayer>[]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(repository.calls, hasLength(2));
    expect(repository.maxActiveRequests, 1);

    repository.calls[1].complete(const <TournamentPlayer>[]);
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'resumed listener ignores completion from the canceled generation',
    () async {
      final repository = _ControlledRosterRepository();
      final container = ProviderContainer(
        overrides: [
          tourRepositoryProvider.overrideWithValue(repository),
          playerTourStandingsSnapshotProvider.overrideWith(
            _EmptySnapshotNotifier.new,
          ),
          tournamentRosterRefreshIntervalProvider.overrideWithValue(
            const Duration(days: 1),
          ),
        ],
      );
      addTearDown(container.dispose);
      final provider = tournamentRosterStandingsProvider('stable-tour');
      final firstSubscription = container.listen(
        provider,
        (previous, next) {},
        fireImmediately: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, hasLength(1));

      firstSubscription.close();
      final resumedSubscription = container.listen(
        provider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(resumedSubscription.close);
      repository.calls.first.complete([
        TournamentPlayer(
          federation: 'USA',
          name: 'Canceled Result',
          fideId: 1,
          played: 1,
          rating: 2400,
          score: 1,
        ),
      ]);
      for (var i = 0; i < 3; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(container.read(provider).valueOrNull, isNull);
      expect(repository.calls, hasLength(2));

      repository.calls[1].complete([
        TournamentPlayer(
          federation: 'USA',
          name: 'Current Result',
          fideId: 2,
          played: 1,
          rating: 2450,
          score: 1,
        ),
      ]);
      for (var i = 0; i < 3; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        container.read(provider).valueOrNull?.single.name,
        'Current Result',
      );
    },
  );

  test('roster refresh timer stops without listeners and restarts', () async {
    final repository = _CountingRosterRepository();
    final container = ProviderContainer(
      overrides: [
        tourRepositoryProvider.overrideWithValue(repository),
        playerTourStandingsSnapshotProvider.overrideWith(
          _EmptySnapshotNotifier.new,
        ),
        tournamentRosterRefreshIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 20),
        ),
      ],
    );
    addTearDown(container.dispose);
    final provider = tournamentRosterStandingsProvider('stable-tour');
    var subscription = container.listen(
      provider,
      (previous, next) {},
      fireImmediately: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(repository.calls, greaterThanOrEqualTo(2));

    subscription.close();
    final callsAfterCancel = repository.calls;
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(repository.calls, callsAfterCancel);

    subscription = container.listen(
      provider,
      (previous, next) {},
      fireImmediately: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(repository.calls, greaterThan(callsAfterCancel));

    subscription.close();
    final callsAfterSecondCancel = repository.calls;
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(repository.calls, callsAfterSecondCancel);
  });
}
