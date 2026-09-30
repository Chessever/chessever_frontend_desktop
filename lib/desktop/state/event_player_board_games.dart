import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'event_player_board_scope.dart';
import 'tournament_games.dart';
import '../widgets/player_hover_preview.dart';
import '../widgets/player_score_card_view.dart';

/// Resolve pagination siblings from the source tour's own parent, never a
/// mutable global event or a sampled rail. Other event categories stay excluded.
Future<EventPlayerBoardScope> resolveEventPlayerBoardScope(
  ProviderContainer container,
  EventPlayerBoardScope seed,
) async {
  final tours = await container
      .read(tourRepositoryProvider)
      .getTourByGroupId(seed.tourIds.first);
  final selected =
      tours.where((tour) => tour.id == seed.tourIds.first).firstOrNull;
  if (selected == null) {
    throw StateError('The event scope is unavailable. Please retry.');
  }
  return EventPlayerBoardScope(
    tourIds: resolveEventPlayerTourIds(
      selectedTourId: selected.id,
      selectedTourName: selected.name,
      eventTours: tours.map((tour) => (id: tour.id, name: tour.name)),
    ),
    playerName: seed.playerName,
    fideId: seed.fideId,
    eventTitle: seed.eventTitle,
    eventBroadcastId: selected.groupBroadcastId ?? seed.eventBroadcastId,
  );
}

EventPlayerGamesKey eventPlayerBoardGamesKey(
  EventPlayerBoardScope scope,
  String ownerId,
) => EventPlayerGamesKey(
  tourId: scope.tourIds.first,
  additionalTourIds: scope.tourIds.skip(1),
  playerName: scope.playerName,
  fideId: scope.fideId,
  ownerId: ownerId,
);

List<TournamentGameSummary> eventPlayerBoardGames(
  EventPlayerBoardScope scope,
  Iterable<TournamentGameSummary> games,
) => playerHoverPreviewGames(
  PlayerHoverPreviewIdentity(name: scope.playerName, fideId: scope.fideId),
  games.where((game) => scope.tourIds.contains(game.tourId)).toList(),
);

/// Keyed by the receiving tab, not the card's former owner. Hidden tabs do not
/// poll; complete history survives rail collapse while the Board owns it.
final eventPlayerBoardGamesProvider = Provider.autoDispose
    .family<AsyncValue<List<TournamentGameSummary>>, EventPlayerGamesKey>((
      ref,
      key,
    ) {
      final rows = ref.watch(eventPlayerGamesProvider(key));
      return rows.whenData(
        (games) => playerHoverPreviewGames(
          PlayerHoverPreviewIdentity(name: key.playerName, fideId: key.fideId),
          games
              .where((game) => key.tourIds.contains(game.tourId))
              .map(TournamentGameSummary.fromGamesTourModel)
              .toList(),
        ),
      );
    });
