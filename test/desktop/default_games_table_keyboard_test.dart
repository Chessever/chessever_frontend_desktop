import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/default_games_table.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

void main() {
  testWidgets('single click highlights and arrows move highlighted game', (
    tester,
  ) async {
    final opened = <String>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _wrap(controller: controller, onOpen: (game) => opened.add(game.gameId)),
    );
    await tester.pump();

    await tester.tap(find.text('White0'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(opened, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(opened, ['game-1']);
  });

  testWidgets('page down moves highlighted row by a fast visible chunk', (
    tester,
  ) async {
    final opened = <String>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _wrap(controller: controller, onOpen: (game) => opened.add(game.gameId)),
    );
    await tester.pump();

    await tester.tap(find.text('White0'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(opened, ['game-8']);
  });
  testWidgets('shift arrow selects a contiguous table range', (tester) async {
    final selected = <String>{};
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _wrap(
        controller: controller,
        onOpen: (_) {},
        selectionMode: true,
        selectedIds: selected,
        onToggleSelection: (id) {
          if (!selected.add(id)) selected.remove(id);
        },
        onReplaceSelection: (ids) {
          selected
            ..clear()
            ..addAll(ids);
        },
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(selected, {'game-0', 'game-1', 'game-2', 'game-3'});
  });
}

Widget _wrap({
  required ScrollController controller,
  required ValueChanged<GamesTourModel> onOpen,
  bool selectionMode = false,
  Set<String> selectedIds = const <String>{},
  ValueChanged<String>? onToggleSelection,
  ValueChanged<Set<String>>? onReplaceSelection,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: kBackgroundColor,
        body: SizedBox(
          width: 720,
          height: 180,
          child: DefaultGamesTable(
            active: true,
            games: List.generate(24, _game),
            controller: controller,
            selectionMode: selectionMode,
            selectedIds: selectedIds,
            onToggleSelection: onToggleSelection,
            onReplaceSelection: onReplaceSelection,
            onOpenGame: (game, {required bool inNewTab}) => onOpen(game),
          ),
        ),
      ),
    ),
  );
}

GamesTourModel _game(int index) {
  return GamesTourModel(
    gameId: 'game-$index',
    whitePlayer: _player('White$index'),
    blackPlayer: _player('Black$index'),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.draw,
    roundId: 'R$index',
    tourId: 'event-$index',
    tourSlug: 'Event $index',
    gameDay: DateTime(2026, 1, index + 1),
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2600,
    countryCode: 'USA',
    team: null,
  );
}
