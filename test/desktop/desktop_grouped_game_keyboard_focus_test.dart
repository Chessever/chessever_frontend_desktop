import 'package:chessever/desktop/widgets/desktop_grouped_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/pane_keyboard_scroll.dart';
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

class _GroupedBoardIdentityProbe extends StatefulWidget {
  const _GroupedBoardIdentityProbe({super.key, required this.gameId});

  final String gameId;

  @override
  State<_GroupedBoardIdentityProbe> createState() =>
      _GroupedBoardIdentityProbeState();
}

class _GroupedBoardIdentityProbeState
    extends State<_GroupedBoardIdentityProbe> {
  @override
  Widget build(BuildContext context) => Text(widget.gameId);
}

void main() {
  testWidgets('group headers and boards form one keyboard hierarchy', (
    tester,
  ) async {
    String? activatedGroup;
    String? activatedGame;
    final groups = [
      DesktopGameKeyboardGroup(
        id: 'event-a',
        games: [_game('a1'), _game('a2')],
      ),
      DesktopGameKeyboardGroup(id: 'event-b', games: [_game('b1')]),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopGroupedGameKeyboardFocus(
          scopeId: 'test',
          groups: groups,
          resolveColumnCount: (_) => 2,
          onActivateGroup: (id) => activatedGroup = id,
          onActivateGame: (game) => activatedGame = game.gameId,
          builder: (
            context,
            selection,
            selectGroup,
            selectGame,
            keyForGroup,
            keyForGame,
          ) {
            return Column(
              children: [
                Text(
                  '${selection?.groupId}:${selection?.gameId ?? 'header'}',
                  key: const Key('selection'),
                ),
                for (final group in groups) ...[
                  DesktopGroupedGameKeyboardHeader(
                    itemKey: keyForGroup(group.id),
                    groupId: group.id,
                    onSelect: selectGroup,
                    child: Text(group.id),
                  ),
                  for (final game in group.games)
                    DesktopGroupedGameKeyboardItem(
                      itemKey: keyForGame(group.id, game.gameId),
                      groupId: group.id,
                      gameId: game.gameId,
                      onSelect: selectGame,
                      child: Text(game.gameId),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('event-a:header'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('event-a:a1'), findsOneWidget);

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      find.text('event-a:a1'),
      findsOneWidget,
      reason: 'key repeat must not skip boards in the hierarchy',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('event-a:a2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('event-b:header'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activatedGroup, 'event-b');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('event-b:b1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activatedGame, 'b1');
  });

  testWidgets('grouped board selection scrolls into view without animation', (
    tester,
  ) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final groups = [
      DesktopGameKeyboardGroup(
        id: 'event-a',
        games: [_game('a1'), _game('a2')],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 100,
              child: DesktopGroupedGameKeyboardFocus(
                scopeId: 'instant-grouped-scroll',
                groups: groups,
                scrollController: scrollController,
                resolveColumnCount: (_) => 1,
                onActivateGame: (_) {},
                builder: (
                  context,
                  selection,
                  selectGroup,
                  selectGame,
                  keyForGroup,
                  keyForGame,
                ) {
                  return ListView(
                    controller: scrollController,
                    children: [
                      DesktopGroupedGameKeyboardHeader(
                        itemKey: keyForGroup('event-a'),
                        groupId: 'event-a',
                        onSelect: selectGroup,
                        child: const SizedBox(
                          height: 70,
                          child: Text('event-a'),
                        ),
                      ),
                      for (final game in groups.first.games)
                        DesktopGroupedGameKeyboardItem(
                          itemKey: keyForGame('event-a', game.gameId),
                          groupId: 'event-a',
                          gameId: game.gameId,
                          onSelect: selectGame,
                          child: SizedBox(
                            height: 70,
                            child: Text(
                              selection?.gameId == game.gameId
                                  ? 'selected:${game.gameId}'
                                  : 'item:${game.gameId}',
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(find.text('selected:a1'), findsOneWidget);
    expect(scrollController.offset, closeTo(40, 0.1));
    expect(scrollController.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('grouped selection keeps each board state on its own game', (
    tester,
  ) async {
    final groups = [
      DesktopGameKeyboardGroup(
        id: 'event-a',
        games: [_game('a1'), _game('a2')],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopGroupedGameKeyboardFocus(
          scopeId: 'stable-grouped-board-identity',
          groups: groups,
          resolveColumnCount: (_) => 2,
          onActivateGame: (_) {},
          builder: (
            context,
            selection,
            selectGroup,
            selectGame,
            keyForGroup,
            keyForGame,
          ) {
            return Column(
              children: [
                DesktopGroupedGameKeyboardHeader(
                  itemKey: keyForGroup('event-a'),
                  groupId: 'event-a',
                  onSelect: selectGroup,
                  child: const Text('event-a'),
                ),
                for (final game in groups.first.games)
                  DesktopGroupedGameKeyboardItem(
                    itemKey: keyForGame('event-a', game.gameId),
                    groupId: 'event-a',
                    gameId: game.gameId,
                    onSelect: selectGame,
                    child: _GroupedBoardIdentityProbe(
                      key: ValueKey<String>('grouped-probe-${game.gameId}'),
                      gameId: game.gameId,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();

    final a1Before = tester.state<_GroupedBoardIdentityProbeState>(
      find.byKey(const ValueKey<String>('grouped-probe-a1')),
    );
    final a2Before = tester.state<_GroupedBoardIdentityProbeState>(
      find.byKey(const ValueKey<String>('grouped-probe-a2')),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(
      tester.state<_GroupedBoardIdentityProbeState>(
        find.byKey(const ValueKey<String>('grouped-probe-a1')),
      ),
      same(a1Before),
    );
    expect(
      tester.state<_GroupedBoardIdentityProbeState>(
        find.byKey(const ValueKey<String>('grouped-probe-a2')),
      ),
      same(a2Before),
    );
  });

  testWidgets('event navigation wins when focus is parked on the outer pane', (
    tester,
  ) async {
    final parkedFocus = FocusNode(debugLabel: 'parked-pane-focus');
    final scrollController = ScrollController();
    addTearDown(parkedFocus.dispose);
    addTearDown(scrollController.dispose);
    final groups = [
      DesktopGameKeyboardGroup(
        id: 'round-1',
        games: [_game('a1'), _game('a2'), _game('a3')],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaneKeyboardScroll(
            child: Column(
              children: [
                Focus(focusNode: parkedFocus, child: const SizedBox(height: 1)),
                Expanded(
                  child: DesktopGroupedGameKeyboardFocus(
                    scopeId: 'event-pane-focus-recovery',
                    groups: groups,
                    scrollController: scrollController,
                    resolveColumnCount: (_) => 1,
                    onActivateGame: (_) {},
                    builder: (
                      context,
                      selection,
                      selectGroup,
                      selectGame,
                      keyForGroup,
                      keyForGame,
                    ) {
                      return Column(
                        children: [
                          Text(
                            '${selection?.groupId}:${selection?.gameId ?? 'header'}',
                            key: const Key('parked-selection'),
                          ),
                          Expanded(
                            child: ListView(
                              controller: scrollController,
                              children: [
                                DesktopGroupedGameKeyboardHeader(
                                  itemKey: keyForGroup('round-1'),
                                  groupId: 'round-1',
                                  onSelect: selectGroup,
                                  child: const SizedBox(
                                    height: 80,
                                    child: Text('round-1'),
                                  ),
                                ),
                                for (final game in groups.first.games)
                                  DesktopGroupedGameKeyboardItem(
                                    itemKey: keyForGame('round-1', game.gameId),
                                    groupId: 'round-1',
                                    gameId: game.gameId,
                                    onSelect: selectGame,
                                    child: SizedBox(
                                      height: 180,
                                      child: Text(game.gameId),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    parkedFocus.requestFocus();
    await tester.pump();
    expect(parkedFocus.hasFocus, isTrue);
    expect(find.text('round-1:header'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(find.text('round-1:a1'), findsOneWidget);
    expect(parkedFocus.hasFocus, isFalse);
  });
}
