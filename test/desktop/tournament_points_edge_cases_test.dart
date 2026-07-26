import 'dart:async';

import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _EmptyLiveSnapshotNotifier extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async =>
      PlayerTourStandingsSnapshot.empty;
}

class _UnknownLiveIdentityNotifier extends PlayerTourScreenNotifier {
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
          ),
        ],
      );
}

class _ControlledLiveIdentityNotifier extends PlayerTourScreenNotifier {
  int publications = 0;

  @override
  Future<PlayerTourStandingsSnapshot> build() async =>
      PlayerTourStandingsSnapshot.empty;

  void publishUnknownIdentity() {
    publications += 1;
    state = AsyncData(
      PlayerTourStandingsSnapshot(
        tourIds: const {'stable-tour'},
        standings: [
          PlayerStandingModel(
            countryCode: const ['USA', 'CAN'][publications % 2],
            name: 'Same, Player',
            score: 2500,
            scoreChange: 0,
            matchScore: '9 / 9',
          ),
        ],
      ),
    );
  }
}

class _PendingRosterRepository implements TourRepository {
  final request = Completer<List<TournamentPlayer>>();
  int calls = 0;

  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) {
    expect(tourId, 'stable-tour');
    calls += 1;
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _EvolvingIdentityRosterRepository implements TourRepository {
  int calls = 0;

  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async {
    expect(tourId, 'stable-tour');
    calls += 1;
    return [
      TournamentPlayer(
        federation: 'USA',
        name: 'Same Player',
        fideId: calls == 1 ? 111 : 222,
        played: 3,
        rating: 2400,
        score: 2,
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ProviderContainer _pendingContainer(_PendingRosterRepository repository) {
  return ProviderContainer(
    overrides: [
      tourRepositoryProvider.overrideWithValue(repository),
      playerTourStandingsSnapshotProvider.overrideWith(
        _EmptyLiveSnapshotNotifier.new,
      ),
      tournamentRosterRefreshIntervalProvider.overrideWithValue(
        const Duration(days: 1),
      ),
      tournamentRosterRetryDelayProvider.overrideWithValue(
        const Duration(days: 1),
      ),
    ],
  );
}

void main() {
  test('in-flight roster success is inert after provider disposal', () async {
    final repository = _PendingRosterRepository();
    final container = _pendingContainer(repository);
    final subscription = container.listen(
      tournamentRosterStandingsProvider('stable-tour'),
      (previous, next) {},
      fireImmediately: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(repository.calls, 1);

    subscription.close();
    container.dispose();
    repository.request.complete(const <TournamentPlayer>[]);
    for (var i = 0; i < 3; i += 1) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(repository.calls, 1);
  });

  test('in-flight roster error is inert after provider disposal', () async {
    final repository = _PendingRosterRepository();
    final container = _pendingContainer(repository);
    final subscription = container.listen(
      tournamentRosterStandingsProvider('stable-tour'),
      (previous, next) {},
      fireImmediately: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(repository.calls, 1);

    subscription.close();
    container.dispose();
    repository.request.completeError(StateError('late roster failure'));
    for (var i = 0; i < 3; i += 1) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(repository.calls, 1);
  });

  test('learned FIDE ID survives live precedence and later conflict', () async {
    final repository = _EvolvingIdentityRosterRepository();
    final container = ProviderContainer(
      overrides: [
        tourRepositoryProvider.overrideWithValue(repository),
        playerTourStandingsSnapshotProvider.overrideWith(
          _UnknownLiveIdentityNotifier.new,
        ),
        tournamentRosterRefreshIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 10),
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
    for (var i = 0; i < 20 && repository.calls < 2; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(Duration.zero);

    final standings = container.read(provider).valueOrNull;
    expect(standings, isNotNull);
    expect(
      standings!.map((standing) => standing.fideId).whereType<int>().toSet(),
      {111, 222},
    );
    expect(
      standings.singleWhere((standing) => standing.fideId == 111).matchScore,
      '9 / 9',
    );
  });

  test(
    'late no-ID live row cannot collapse conflicting FIDE identities',
    () async {
      final repository = _EvolvingIdentityRosterRepository();
      final container = ProviderContainer(
        overrides: [
          tourRepositoryProvider.overrideWithValue(repository),
          playerTourStandingsSnapshotProvider.overrideWith(
            _ControlledLiveIdentityNotifier.new,
          ),
          tournamentRosterRefreshIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 10),
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
      for (var i = 0; i < 20 && repository.calls < 2; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final beforeLive = container.read(provider).valueOrNull;
      expect(
        beforeLive!.map((standing) => standing.fideId).whereType<int>().toSet(),
        {111, 222},
      );

      final liveNotifier =
          container.read(playerTourStandingsSnapshotProvider.notifier)
              as _ControlledLiveIdentityNotifier;
      liveNotifier.publishUnknownIdentity();
      for (var i = 0; i < 3; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      final afterLive = container.read(provider).valueOrNull;
      expect(
        afterLive!.map((standing) => standing.fideId).whereType<int>().toSet(),
        {111, 222},
      );
      expect(afterLive, hasLength(3));

      liveNotifier.publishUnknownIdentity();
      for (var i = 0; i < 3; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      final afterRepeatedLive = container.read(provider).valueOrNull;
      expect(afterRepeatedLive, hasLength(3));
      expect(
        afterRepeatedLive!.where((standing) => standing.fideId == null),
        hasLength(1),
      );
    },
  );
}
