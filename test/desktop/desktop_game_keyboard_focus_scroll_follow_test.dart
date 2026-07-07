import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

GamesTourModel _game(String id) {
  return GamesTourModel(
    gameId: id,
    source: GameSource.twic,
    whitePlayer: _player('White $id'),
    blackPlayer: _player('Black $id'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.ongoing,
    roundId: 'round-1',
    tourId: 'event-1',
    lastMoveTime: DateTime.utc(2026),
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: 2700,
    countryCode: '',
    team: null,
  );
}

/// A 3-column grid taller than its viewport, wired through
/// [DesktopGameKeyboardFocus] the same way the real panes do.
class _GridHost extends StatelessWidget {
  const _GridHost({required this.controller, required this.games});

  final ScrollController controller;
  final List<GamesTourModel> games;

  static const int columns = 3;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 900,
            height: 300, // ~3 rows tall so most of the grid is off-screen
            child: DesktopGameKeyboardFocus(
              scopeId: 'scroll-follow',
              games: games,
              resolveColumnCount: () => columns,
              builder: (context, selectedGameId, selectGame, keyForGame) {
                return CustomScrollView(
                  controller: controller,
                  slivers: [
                    SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisExtent: 120,
                          ),
                      delegate: SliverChildBuilderDelegate((context, i) {
                        final game = games[i];
                        return DesktopGameKeyboardItem(
                          itemKey: keyForGame(game.gameId),
                          gameId: game.gameId,
                          onSelect: selectGame,
                          child: ColoredBox(
                            key: ValueKey('box-${game.gameId}'),
                            color:
                                selectedGameId == game.gameId
                                    ? Colors.blue
                                    : Colors.grey,
                            child: Center(child: Text(game.gameId)),
                          ),
                        );
                      }, childCount: games.length),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'scroll position follows the keyboard selection down and back up',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final games = List.generate(30, (i) => _game('g$i'));

      await tester.pumpWidget(_GridHost(controller: controller, games: games));
      await tester.pumpAndSettle();

      expect(controller.offset, 0);

      // Walk down several rows — each ArrowDown jumps a full row of 3 cards.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      final offsetAfterDown = controller.offset;
      expect(
        offsetAfterDown,
        greaterThan(0),
        reason: 'ArrowDown must scroll the viewport to keep selection visible',
      );

      // Walk back up — this is the regression guard: keepVisibleAtEnd alone
      // refuses to scroll backward, so ArrowUp would leave the offset pinned.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      expect(
        controller.offset,
        lessThan(offsetAfterDown),
        reason: 'ArrowUp must scroll the viewport back toward the top',
      );
      expect(controller.offset, 0);
    },
  );

  testWidgets('ArrowDown selects the card one row below (not the next card)', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final games = List.generate(12, (i) => _game('g$i'));

    await tester.pumpWidget(_GridHost(controller: controller, games: games));
    await tester.pumpAndSettle();

    // Selection starts on g0. One row down in a 3-column grid is g3.
    Color colorFor(String id) {
      return tester
          .widget<ColoredBox>(find.byKey(ValueKey('box-$id')))
          .color;
    }

    expect(colorFor('g0'), Colors.blue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(colorFor('g3'), Colors.blue);
    expect(colorFor('g0'), Colors.grey);
    expect(colorFor('g1'), Colors.grey);
  });
}
