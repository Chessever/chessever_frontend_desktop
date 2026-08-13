import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/player_hover_preview.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

void main() {
  const player = PlayerHoverPreviewIdentity(
    name: 'Tiviakov, Sergei',
    federation: 'NED',
    title: 'GM',
    rating: 2530,
    fideId: 1001,
  );

  test('known FIDE-ID mismatch does not fall back to a same-name game', () {
    final mismatched = TournamentGameSummary(
      id: 'mismatch',
      name: 'Wrong identity',
      whitePlayer: player.name,
      blackPlayer: 'Other Player',
      whiteFideId: 9999,
      blackFideId: 8888,
      hasPgn: true,
    );

    expect(playerHoverPreviewGames(player, [mismatched]), isEmpty);
  });

  test('player games are sorted with the latest round first', () {
    final games = [
      _gameAtRound(id: 'round-7', round: '7'),
      _gameAtRound(id: 'round-8', round: '8'),
      _gameAtRound(id: 'round-6', round: '6'),
    ];

    expect(playerHoverPreviewGames(player, games).map((game) => game.id), [
      'round-8',
      'round-7',
      'round-6',
    ]);
  });

  testWidgets('blank row space does not trigger the exact-name hover', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(player: player, games: _games(2)));
    final pointer = TestPointer(10, PointerDeviceKind.mouse);
    final host = find.byKey(
      const ValueKey<String>('player-hover-preview-host'),
    );
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );
    final hostRect = tester.getRect(host);
    final triggerRect = tester.getRect(trigger);
    expect(triggerRect.width, lessThan(hostRect.width));

    await tester.sendEventToBinding(
      pointer.hover(Offset(hostRect.right - 3, hostRect.center.dy)),
    );
    await tester.pump(
      playerHoverIntentDelay + const Duration(milliseconds: 120),
    );
    expect(
      find.byKey(const ValueKey<String>('player-hover-preview-card')),
      findsNothing,
    );
  });

  testWidgets('player/context replacement cancels stale hover intent', (
    tester,
  ) async {
    final pointer = TestPointer(11, PointerDeviceKind.mouse);
    await tester.pumpWidget(
      _wrap(player: player, games: _games(2), contextKey: 'game-a'),
    );
    var trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(trigger)));
    await tester.pump(const Duration(milliseconds: 130));

    const replacement = PlayerHoverPreviewIdentity(
      name: 'Nepomniachtchi, Ian',
      federation: 'FID',
      title: 'GM',
      rating: 2750,
      fideId: 1002,
    );
    await tester.pumpWidget(
      _wrap(player: replacement, games: _games(2), contextKey: 'game-b'),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey<String>('player-hover-preview-card')),
      findsNothing,
    );

    await tester.sendEventToBinding(pointer.hover(const Offset(4, 4)));
    await tester.pump();
    trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );
    await _open(tester, pointer, trigger);
    final card = find.byKey(
      const ValueKey<String>('player-hover-preview-card'),
    );
    expect(
      find.descendant(of: card, matching: find.text('Nepomniachtchi, Ian')),
      findsOneWidget,
    );
  });

  testWidgets('hover intent opens the card and highlights the exact name', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(player: player, games: _games(6)));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await tester.sendEventToBinding(pointer.hover(tester.getCenter(trigger)));
    await tester.pump(playerHoverIntentDelay - const Duration(milliseconds: 1));
    expect(
      find.byKey(const ValueKey<String>('player-hover-preview-card')),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.byKey(const ValueKey<String>('player-hover-preview-card')),
      findsOneWidget,
    );
    final animated = tester.widget<AnimatedContainer>(trigger);
    final decoration = animated.decoration! as BoxDecoration;
    expect(decoration.color, kPrimaryColor.withValues(alpha: 0.18));
  });

  testWidgets('dismissed preview reports close after reporting open', (
    tester,
  ) async {
    var opened = 0;
    var closed = 0;
    await tester.pumpWidget(
      _wrap(
        player: player,
        games: _games(2),
        onPreviewOpened: () => opened += 1,
        onPreviewClosed: () => closed += 1,
      ),
    );
    final pointer = TestPointer(19, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );
    await _open(tester, pointer, trigger);
    expect(opened, 1);
    expect(closed, 0);

    await tester.sendEventToBinding(pointer.down(const Offset(4, 4)));
    await tester.pumpAndSettle();

    expect(closed, 1);
  });

  testWidgets('card header shows event rating change and score', (
    tester,
  ) async {
    const playerWithEventMetrics = PlayerHoverPreviewIdentity(
      name: 'Schulze, Lara',
      federation: 'GER',
      title: 'FM',
      rating: 2326,
      ratingChange: 19,
      pointsText: '6.5 / 9',
      fideId: 12956830,
    );
    await tester.pumpWidget(
      _wrap(player: playerWithEventMetrics, games: _games(6)),
    );
    final pointer = TestPointer(12, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    final card = find.byKey(
      const ValueKey<String>('player-hover-preview-card'),
    );
    expect(
      find.descendant(of: card, matching: find.text('+19')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Score 6.5')),
      findsOneWidget,
    );
  });

  testWidgets('card header player name opens that player profile', (
    tester,
  ) async {
    PlayerHoverPreviewIdentity? openedPlayer;
    await tester.pumpWidget(
      _wrap(
        player: player,
        games: _games(3),
        onOpenPlayer: (value) => openedPlayer = value,
      ),
    );
    final pointer = TestPointer(15, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    await tester.tap(
      find.byKey(const ValueKey<String>('player-hover-header-name')),
    );
    await tester.pumpAndSettle();

    expect(openedPlayer, same(player));
    expect(
      find.byKey(const ValueKey<String>('player-hover-preview-card')),
      findsNothing,
    );
  });

  testWidgets('round labels use brighter compact text', (tester) async {
    await tester.pumpWidget(_wrap(player: player, games: _games(6)));
    final pointer = TestPointer(16, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    final round = tester.widget<Text>(
      find.byKey(const ValueKey<String>('game-round-game-5')),
    );

    expect(round.style?.color, kWhiteColor70);
    expect(round.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('result circles show the profiled player piece color', (
    tester,
  ) async {
    final games = <TournamentGameSummary>[
      TournamentGameSummary(
        id: 'draw-as-white',
        name: 'Draw as White',
        whitePlayer: player.name,
        blackPlayer: 'Black Opponent',
        whiteFideId: player.fideId,
        blackFideId: 2001,
        roundLabel: '2',
        status: GameStatus.draw,
        hasPgn: true,
      ),
      TournamentGameSummary(
        id: 'draw-as-black',
        name: 'Draw as Black',
        whitePlayer: 'White Opponent',
        blackPlayer: player.name,
        whiteFideId: 2002,
        blackFideId: player.fideId,
        roundLabel: '1',
        status: GameStatus.draw,
        hasPgn: true,
      ),
    ];
    await tester.pumpWidget(_wrap(player: player, games: games));
    final pointer = TestPointer(20, PointerDeviceKind.mouse);
    await _open(
      tester,
      pointer,
      find.byKey(const ValueKey<String>('player-hover-preview-trigger')),
    );

    BoxDecoration circleDecoration(String gameId) {
      final circle = find.descendant(
        of: find.byKey(ValueKey<String>('game-result-$gameId')),
        matching: find.byType(Container),
      );
      return tester.widget<Container>(circle).decoration! as BoxDecoration;
    }

    TextStyle glyphStyle(String gameId) {
      final glyph = find.descendant(
        of: find.byKey(ValueKey<String>('game-result-$gameId')),
        matching: find.text('½'),
      );
      return tester.widget<Text>(glyph).style!;
    }

    expect(circleDecoration('draw-as-white').color, kWhiteColor);
    expect(glyphStyle('draw-as-white').color, kBlackColor);
    expect(circleDecoration('draw-as-black').color, kBlackColor);
    expect(glyphStyle('draw-as-black').color, kWhiteColor);
  });

  testWidgets('opponent ratings sit beside the opponent name', (tester) async {
    await tester.pumpWidget(_wrap(player: player, games: _games(6)));
    final pointer = TestPointer(17, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    final name = find.byKey(const ValueKey<String>('opponent-name-game-5'));
    final rating = find.byKey(const ValueKey<String>('opponent-rating-game-5'));

    expect(
      tester.getTopLeft(rating).dx - tester.getTopRight(name).dx,
      closeTo(6, 0.1),
    );
  });

  testWidgets('game list uses a wider draggable scrollbar thumb', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(player: player, games: _games(6)));
    final pointer = TestPointer(18, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    final card = find.byKey(
      const ValueKey<String>('player-hover-preview-card'),
    );
    final scrollbar = tester.widget<Scrollbar>(
      find.descendant(of: card, matching: find.byType(Scrollbar)),
    );

    expect(scrollbar.thickness, 10);
    expect(scrollbar.radius, const Radius.circular(5));
  });

  testWidgets(
    'pointer transfer keeps the card open then grace-closes outside',
    (tester) async {
      await tester.pumpWidget(_wrap(player: player, games: _games(6)));
      final pointer = TestPointer(2, PointerDeviceKind.mouse);
      final trigger = find.byKey(
        const ValueKey<String>('player-hover-preview-trigger'),
      );

      await _open(tester, pointer, trigger);
      final card = find.byKey(
        const ValueKey<String>('player-hover-preview-card'),
      );
      await tester.sendEventToBinding(pointer.hover(tester.getCenter(card)));
      await tester.pump(
        playerHoverGraceDelay + const Duration(milliseconds: 80),
      );
      expect(card, findsOneWidget);

      await tester.sendEventToBinding(pointer.hover(const Offset(4, 4)));
      await tester.pump(playerHoverGraceDelay);
      await tester.pump(const Duration(milliseconds: 120));
      expect(card, findsNothing);
    },
  );

  test(
    'dismiss safety zone tolerates nearby movement but rejects far movement',
    () {
      const triggerRect = Rect.fromLTWH(180, 100, 160, 28);
      const cardRect = Rect.fromLTWH(180, 134, 420, 300);

      expect(
        isPlayerHoverPointerNearby(
          pointer: const Offset(618, 280),
          triggerRect: triggerRect,
          cardRect: cardRect,
        ),
        isTrue,
      );
      expect(
        isPlayerHoverPointerNearby(
          pointer: const Offset(40, 40),
          triggerRect: triggerRect,
          cardRect: cardRect,
        ),
        isFalse,
      );
    },
  );

  testWidgets('outside click dismisses the card immediately', (tester) async {
    await tester.pumpWidget(_wrap(player: player, games: _games(6)));
    final pointer = TestPointer(14, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    final card = find.byKey(
      const ValueKey<String>('player-hover-preview-card'),
    );
    expect(card, findsOneWidget);

    await tester.sendEventToBinding(pointer.down(const Offset(4, 4)));
    await tester.sendEventToBinding(pointer.up());
    await tester.pumpAndSettle();
    expect(card, findsNothing);
  });

  testWidgets('opponent name and score circle open new app tabs', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final games = _games(3);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: Center(
              child: SizedBox(
                width: 260,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Consumer(
                    builder:
                        (context, ref, _) => PlayerHoverPreview(
                          player: player,
                          games: games,
                          onOpenOpponentInNewTab: (opponent) {
                            final args = PlayerProfileArgs(
                              playerName: opponent.name,
                              fideId: opponent.fideId,
                              title: opponent.title,
                              federation: opponent.federation,
                              rating: opponent.rating,
                            );
                            openPlayerProfile(
                              ref,
                              args,
                              focus: true,
                              reuseExisting: false,
                            );
                          },
                          onOpenGameInNewTab: (game) {
                            openBoardGameTab(
                              ref,
                              BoardTabGameArgs(
                                gameId: game.id,
                                pgn: game.pgn ?? '',
                                label: game.name,
                                whiteName: game.whitePlayer,
                                blackName: game.blackPlayer,
                                whiteFederation: game.whiteFederation,
                                blackFederation: game.blackFederation,
                                whiteTitle: game.whiteTitle,
                                blackTitle: game.blackTitle,
                                whiteRating: game.whiteRating,
                                blackRating: game.blackRating,
                                whiteFideId: game.whiteFideId,
                                blackFideId: game.blackFideId,
                                eventGames: games,
                              ),
                              focus: true,
                              reuseExisting: false,
                              replaceActive: false,
                            );
                          },
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final initialTabs = container.read(desktopTabsProvider);
    final originalActiveId = initialTabs.activeId;
    final originalBoardCount =
        initialTabs.tabs.where((tab) => tab.kind == TabKind.board).length;
    final pointer = TestPointer(3, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    await tester.tap(
      find.byKey(const ValueKey<String>('opponent-name-game-0')),
    );
    await tester.pump();
    var tabs = container.read(desktopTabsProvider);
    expect(
      tabs.tabs.where((tab) => tab.kind == TabKind.playerProfile),
      hasLength(1),
    );
    expect(tabs.activeId, isNot(originalActiveId));
    expect(
      tabs.tabs.singleWhere((tab) => tab.id == tabs.activeId).kind,
      TabKind.playerProfile,
    );

    await tester.sendEventToBinding(pointer.hover(const Offset(4, 4)));
    await tester.pump(const Duration(milliseconds: 140));
    await _open(tester, pointer, trigger);
    await tester.tap(
      find.byKey(const ValueKey<String>('opponent-name-game-0')),
    );
    await tester.pump();
    tabs = container.read(desktopTabsProvider);
    expect(
      tabs.tabs.where((tab) => tab.kind == TabKind.playerProfile),
      hasLength(2),
    );

    await tester.sendEventToBinding(pointer.hover(const Offset(4, 4)));
    await tester.pump(const Duration(milliseconds: 140));
    await _open(tester, pointer, trigger);
    await tester.tap(find.byKey(const ValueKey<String>('game-result-game-0')));
    await tester.pump();
    tabs = container.read(desktopTabsProvider);
    expect(
      tabs.tabs.where((tab) => tab.kind == TabKind.board),
      hasLength(originalBoardCount + 1),
    );
    expect(tabs.activeId, isNot(originalActiveId));
    expect(
      tabs.tabs.singleWhere((tab) => tab.id == tabs.activeId).kind,
      TabKind.board,
    );
  });

  testWidgets('wheel scrolling inside the card preserves the popover', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(player: player, games: _games(12)));
    final pointer = TestPointer(4, PointerDeviceKind.mouse);
    final trigger = find.byKey(
      const ValueKey<String>('player-hover-preview-trigger'),
    );

    await _open(tester, pointer, trigger);
    final card = find.byKey(
      const ValueKey<String>('player-hover-preview-card'),
    );
    final scroll = find.byKey(
      const ValueKey<String>('player-hover-preview-scroll'),
    );
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(scroll)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 180)));
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scroll, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.pixels, greaterThan(0));
    await tester.pump(playerHoverGraceDelay + const Duration(milliseconds: 80));
    expect(card, findsOneWidget);
  });

  testWidgets(
    'ordinary trigger click still reaches the existing name handler',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: GestureDetector(
                  onTap: () => taps++,
                  child: SizedBox(
                    width: 260,
                    child: PlayerHoverPreview(
                      player: player,
                      games: _games(1),
                      onOpenOpponentInNewTab: (_) {},
                      onOpenGameInNewTab: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Tiviakov, Sergei').first);
      await tester.pump();
      expect(taps, 1);
    },
  );
}

Future<void> _open(
  WidgetTester tester,
  TestPointer pointer,
  Finder trigger,
) async {
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(trigger)));
  await tester.pump(playerHoverIntentDelay);
  await tester.pump(const Duration(milliseconds: 120));
  expect(
    find.byKey(const ValueKey<String>('player-hover-preview-card')),
    findsOneWidget,
  );
}

Widget _wrap({
  required PlayerHoverPreviewIdentity player,
  required List<TournamentGameSummary> games,
  ValueChanged<PlayerHoverPreviewIdentity>? onOpenPlayer,
  ValueChanged<PlayerHoverPreviewIdentity>? onOpenOpponent,
  ValueChanged<TournamentGameSummary>? onOpenGame,
  VoidCallback? onPreviewOpened,
  VoidCallback? onPreviewClosed,
  String contextKey = '',
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: kBackgroundColor,
        body: Center(
          child: SizedBox(
            key: const ValueKey<String>('player-hover-preview-host'),
            width: 260,
            child: Align(
              alignment: Alignment.centerLeft,
              child: PlayerHoverPreview(
                player: player,
                games: games,
                contextKey: contextKey,
                onPreviewOpened: onPreviewOpened,
                onPreviewClosed: onPreviewClosed,
                onOpenPlayerInNewTab: onOpenPlayer ?? (_) {},
                onOpenOpponentInNewTab: onOpenOpponent ?? (_) {},
                onOpenGameInNewTab: onOpenGame ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

List<TournamentGameSummary> _games(int count) {
  return List<TournamentGameSummary>.generate(
    count,
    (index) => TournamentGameSummary(
      id: 'game-$index',
      name: 'Game $index',
      whitePlayer: 'Tiviakov, Sergei',
      blackPlayer: 'Opponent $index',
      whiteFederation: 'NED',
      blackFederation: index.isEven ? 'GER' : 'USA',
      whiteTitle: 'GM',
      blackTitle: index.isEven ? 'GM' : 'IM',
      whiteRating: 2530,
      blackRating: 2500 + index,
      whiteFideId: 1001,
      blackFideId: 2000 + index,
      hasPgn: true,
      pgn: '1. e4 e5 *',
      tourId: 'tour-1',
      tourSlug: 'Dutch Championship',
      roundId: 'round-${index + 1}',
      roundSlug: 'round-${index + 1}',
      roundLabel: '${index + 1}',
      status:
          index % 3 == 0
              ? GameStatus.whiteWins
              : index % 3 == 1
              ? GameStatus.draw
              : GameStatus.blackWins,
    ),
  );
}

TournamentGameSummary _gameAtRound({
  required String id,
  required String round,
}) {
  return TournamentGameSummary(
    id: id,
    name: id,
    whitePlayer: 'Tiviakov, Sergei',
    blackPlayer: 'Opponent $round',
    whiteFideId: 1001,
    blackFideId: 2000 + int.parse(round),
    hasPgn: true,
    roundId: 'round-$round',
    roundSlug: 'round-$round',
    roundLabel: round,
  );
}
