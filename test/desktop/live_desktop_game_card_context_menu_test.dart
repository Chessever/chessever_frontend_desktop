import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class _FakeGameStreamRepository extends GameStreamRepository {
  @override
  Stream<Map<String, dynamic>?> subscribeToGameUpdates(String gameId) {
    return const Stream.empty();
  }
}

void main() {
  testWidgets('finished live game cards can be saved from right-click menu', (
    tester,
  ) async {
    await _pumpCard(tester, _game(status: GameStatus.whiteWins));

    await _openContextMenu(tester);

    expect(find.text('Save to library'), findsOneWidget);
  });

  testWidgets('ongoing live game cards omit save-to-library action', (
    tester,
  ) async {
    await _pumpCard(tester, _game(status: GameStatus.ongoing));

    await _openContextMenu(tester);

    expect(find.text('Save to library'), findsNothing);
    expect(find.text('Share Game'), findsOneWidget);
  });
}

Future<void> _pumpCard(WidgetTester tester, GamesTourModel game) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gameStreamRepositoryProvider.overrideWithValue(
          _FakeGameStreamRepository(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              child: LiveDesktopGameCard(
                game: game,
                tournamentTitle: 'Test Event',
                layout: DesktopCardLayout.compact,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openContextMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byType(DesktopGameCard)),
    buttons: kSecondaryMouseButton,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

GamesTourModel _game({required GameStatus status}) {
  return GamesTourModel(
    gameId: 'game-${status.name}',
    whitePlayer: _player('White'),
    blackPlayer: _player('Black'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'tour-1',
    tourSlug: 'test-event',
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
