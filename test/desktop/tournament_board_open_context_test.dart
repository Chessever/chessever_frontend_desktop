import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class _DelayedGameRepository implements GameRepository {
  final Completer<Games> hydration = Completer<Games>();

  @override
  Future<Games> getGameWithPGN(String gameId) => hydration.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets(
    'For You Board open keeps parent event context on every tab path',
    (tester) async {
      late BoardTabGameArgs args;
      late GameTabDragPayload dragPayload;
      final game = GamesTourModel(
        gameId: 'game-1',
        whitePlayer: _player('White'),
        blackPlayer: _player('Black'),
        whiteTimeDisplay: '05:00',
        blackTimeDisplay: '05:00',
        whiteClockCentiseconds: 30000,
        blackClockCentiseconds: 30000,
        gameStatus: GameStatus.ongoing,
        roundId: 'round-1',
        tourId: 'child-tour',
        tourSlug: 'event',
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                args = buildTournamentBoardTabArgs(
                  game,
                  'Event',
                  eventBroadcastId: 'parent-event',
                );
                dragPayload = tournamentGameDragPayload(
                  game,
                  'Event',
                  eventBroadcastId: 'parent-event',
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(args.eventBroadcastId, 'parent-event');
      expect(args.copyWith(label: 'Updated').eventBroadcastId, 'parent-event');
      expect(dragPayload.eventBroadcastId, 'parent-event');
      expect(
        forYouEventBroadcastIdFromScopeId(
          'for_you:parent-event:child-tour:batch',
        ),
        'parent-event',
      );
      expect(
        forYouEventBroadcastIdFromScopeId('desktop_context:game-1'),
        isNull,
      );
    },
  );

  testWidgets(
    'detached-window open survives card disposal and keeps parent event context',
    (tester) async {
      final repository = _DelayedGameRepository();
      final showCard = ValueNotifier<bool>(true);
      addTearDown(showCard.dispose);
      late Future<void> openFuture;
      DesktopBoardWindowPayload? openedPayload;
      final game = GamesTourModel(
        gameId: 'game-window',
        source: GameSource.supabase,
        whitePlayer: _player('White'),
        blackPlayer: _player('Black'),
        whiteTimeDisplay: '05:00',
        blackTimeDisplay: '05:00',
        whiteClockCentiseconds: 30000,
        blackClockCentiseconds: 30000,
        gameStatus: GameStatus.ongoing,
        roundId: 'round-1',
        tourId: 'child-tour',
        tourSlug: 'event',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gameRepositoryProvider.overrideWithValue(repository),
            desktopBoardWindowServiceProvider.overrideWithValue(
              DesktopBoardWindowService(
                createWindow: (payload) async => openedPayload = payload,
              ),
            ),
          ],
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: showCard,
              builder:
                  (context, visible, child) =>
                      visible
                          ? Consumer(
                            builder: (context, ref, child) {
                              final container = ProviderScope.containerOf(
                                context,
                                listen: false,
                              );
                              return TextButton(
                                onPressed: () {
                                  openFuture = openTournamentGameWindow(
                                    container: container,
                                    game: game,
                                    tournamentTitle: 'Event',
                                    eventBroadcastId: 'parent-event',
                                  );
                                },
                                child: const Text('Open window'),
                              );
                            },
                          )
                          : const SizedBox.shrink(),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open window'));
      await tester.pump();
      showCard.value = false;
      await tester.pump();
      repository.hydration.completeError(StateError('offline'));
      await openFuture;

      expect(openedPayload?.args?.gameId, 'game-window');
      expect(openedPayload?.args?.eventBroadcastId, 'parent-event');
    },
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: null,
  );
}
