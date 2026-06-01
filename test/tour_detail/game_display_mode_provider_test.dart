import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/game_display_mode_provider.dart';

void main() {
  test('game display mode is scoped per tournament id', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(gameDisplayModeProvider('event-a')),
      GameDisplayMode.all,
    );
    expect(
      container.read(gameDisplayModeProvider('event-b')),
      GameDisplayMode.all,
    );

    container.read(gameDisplayModeProvider('event-a').notifier).state =
        GameDisplayMode.hideFinishedGames;

    expect(
      container.read(gameDisplayModeProvider('event-a')),
      GameDisplayMode.hideFinishedGames,
    );
    expect(
      container.read(gameDisplayModeProvider('event-b')),
      GameDisplayMode.all,
    );
  });
}
