import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/event_favorite_players_provider.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/sorting_all_event_provider.dart';

GroupEventCardModel _event({
  required String id,
  required String title,
  required int elo,
}) {
  return GroupEventCardModel(
    id: id,
    title: title,
    dates: 'Nov 10, 2026',
    maxAvgElo: elo,
    timeUntilStart: '',
    tourEventCategory: TourEventCategory.live,
    timeControl: 'Blitz',
    endDate: null,
    startDate: null,
  );
}

EventFavoritePlayers _hearts(int count) {
  return EventFavoritePlayers(
    count: count,
    fideIds: List<int>.generate(count, (index) => index + 1),
  );
}

void main() {
  test('events with favourite players bubble above stronger unhearted ones', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sorted = container
        .read(tournamentSortingServiceProvider)
        .sortBasedOnFavorite(
          tours: <GroupEventCardModel>[
            _event(id: 'regular', title: 'Pol Final', elo: 2329),
            _event(id: 'heart-4', title: 'Titled Tuesday', elo: 2674),
            _event(id: 'heart-1', title: 'Presidents Cup', elo: 2499),
          ],
          favorites: const <String>[],
          eventFavoritePlayersMap: <String, EventFavoritePlayers>{
            'heart-4': _hearts(4),
            'heart-1': _hearts(1),
          },
        );

    expect(
      sorted.map((event) => event.id).toList(),
      <String>['heart-4', 'heart-1', 'regular'],
    );
  });

  test('a starred event outranks hearted events', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sorted = container
        .read(tournamentSortingServiceProvider)
        .sortBasedOnFavorite(
          tours: <GroupEventCardModel>[
            _event(id: 'heart-4', title: 'Titled Tuesday', elo: 2674),
            _event(id: 'starred', title: 'Presidents Cup', elo: 2499),
          ],
          favorites: const <String>['starred'],
          eventFavoritePlayersMap: <String, EventFavoritePlayers>{
            'heart-4': _hearts(4),
          },
        );

    expect(sorted.first.id, 'starred');
    expect(sorted.last.id, 'heart-4');
  });
}
