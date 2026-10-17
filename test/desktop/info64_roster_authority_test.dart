import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/screens/group_event/model/about_tour_model.dart';
import 'package:chessever/screens/group_event/model/tour_detail_view_model.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _LiveRows extends PlayerTourScreenNotifier {
  @override
  Future<PlayerTourStandingsSnapshot> build() async =>
      const PlayerTourStandingsSnapshot(
        tourIds: {'event'},
        standings: [
          PlayerStandingModel(
            countryCode: '',
            name: 'Published Player',
            fideId: 1,
            score: 2000,
            scoreChange: 0,
            matchScore: '9 / 9',
          ),
          PlayerStandingModel(
            countryCode: '',
            name: 'Feed-only Player',
            fideId: 2,
            score: 2000,
            scoreChange: 0,
            matchScore: '8 / 9',
          ),
        ],
      );
}

class _Roster implements TourRepository {
  @override
  Future<List<TournamentPlayer>> getTourPlayers(String tourId) async => [
    TournamentPlayer(
      name: 'Published Player',
      fideId: 1,
      rank: 1,
      score: 2,
      played: 3,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  for (final (url, authoritative) in [
    ('https://info64.org/world-g17/standings', true),
    ('https://other.test/world-g17/standings', false),
    ('https://info64.org/team/world/standings', false),
  ]) {
    test('board standings respect Info64 source authority: $url', () async {
      final tour = Tour.fromJson({
        'id': 'event',
        'name': 'Event',
        'slug': 'event',
        'created_at': '2026-10-15T00:00:00Z',
        'url': '',
        'tier': 1,
        'dates': [],
        'players': [],
        'info': {
          'standings': url,
          'standingsSource': 'info64',
          'standingsUpdatedAt': '2026-10-15T00:00:00Z',
        },
      });
      final container = ProviderContainer(
        overrides: [
          selectedBroadcastModelProvider.overrideWith((ref) => null),
          tourRepositoryProvider.overrideWithValue(_Roster()),
          playerTourStandingsSnapshotProvider.overrideWith(_LiveRows.new),
          tournamentRosterRefreshIntervalProvider.overrideWithValue(
            const Duration(days: 1),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(tourDetailScreenProvider.notifier)
          .setDataState(
            TourDetailViewModel(
              aboutTourModel: AboutTourModel.fromTour(tour),
              liveTourIds: const [],
              tours: [
                TourModel(tour: tour, roundStatus: RoundStatus.completed),
              ],
            ),
          );
      final provider = tournamentRosterStandingsProvider('event');
      container.listen(provider, (_, _) {});
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final rows = container.read(provider).requireValue;
      expect(
        rows.map((row) => row.name),
        authoritative
            ? ['Published Player']
            : ['Published Player', 'Feed-only Player'],
      );
      expect(rows.first.matchScore, authoritative ? '2 / 3' : '9 / 9');
      if (authoritative) expect(rows.first.overallRank, 1);
    });
  }
}
