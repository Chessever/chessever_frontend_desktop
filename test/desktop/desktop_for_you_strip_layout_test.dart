import 'dart:io';

import 'package:chessever/desktop/widgets/desktop_for_you_game_context.dart';
import 'package:chessever/desktop/widgets/desktop_for_you_strip_layout.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop For You does not hydrate full tours per event', () {
    final source =
        File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

    expect(source, isNot(contains('_forYouFullEventGamesProvider')));
    expect(source, isNot(contains('ref.watch(gamesTourProvider(tourId))')));
  });

  test('For You selection anchors stay attached to their own cards', () {
    final source =
        File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

    expect(source, isNot(contains('final GlobalKey _selectedItemKey')));
    expect(source, contains('key: eventItemKey'));
    expect(
      source,
      contains(
        'return KeyedSubtree(key: gameItemKeyFor(gameId), child: child);',
      ),
    );
    expect(source, contains('key: gameItemKeyFor(games[i].gameId)'));
  });

  test(
    'For You event summary card paints selection chrome outside any clip',
    () {
      final source =
          File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

      final classStart = source.indexOf(
        'class _ForYouEventSummaryCardState extends State<_ForYouEventSummaryCard>',
      );
      expect(classStart, greaterThanOrEqualTo(0));

      // Next top-level class after the summary card state ends the region.
      final nextClass = source.indexOf(
        '\nclass _ForYouEventInfoPanel',
        classStart,
      );
      expect(nextClass, greaterThan(classStart));
      final cardSource = source.substring(classStart, nextClass);

      // Fail mode: Container(clipBehavior: Clip.antiAlias, decoration: border/shadow)
      // crops the selection ring and glow. Outer shell must not clip.
      expect(cardSource, isNot(contains('clipBehavior: Clip.antiAlias')));
      expect(cardSource, isNot(contains('clipBehavior: Clip.hardEdge')));
      expect(cardSource, isNot(contains('clipBehavior: Clip.antiAliasWithSaveLayer')));

      // Content rounding is a separate inner clip (desktop_game_card pattern).
      expect(cardSource, contains('ClipRRect'));
      expect(cardSource, contains('borderRadius: BorderRadius.circular(9)'));

      // Selected decoration: primary-tinted border width ≥ 2 + soft glow.
      expect(cardSource, contains('width: widget.selected ? 2 : 1'));
      expect(
        cardSource,
        contains('kPrimaryColor.withValues(alpha: 0.96)'),
      );
      expect(
        cardSource,
        contains('kPrimaryColor.withValues(alpha: 0.16)'),
      );
      expect(cardSource, contains('blurRadius: 8'));

      // Hover chrome shares the same non-clipped shell (white border at 0.12).
      expect(
        cardSource,
        contains('kWhiteColor.withValues(alpha: 0.12)'),
      );

      // Decoration host is a Container with BoxDecoration — not also clipping.
      expect(cardSource, contains('decoration: BoxDecoration('));
      // ClipRRect must be a child of the decorated shell, not a sibling clip host.
      final decorationIndex = cardSource.indexOf('decoration: BoxDecoration(');
      final clipRRectIndex = cardSource.indexOf('ClipRRect(');
      expect(clipRRectIndex, greaterThan(decorationIndex));
    },
  );

  group('DesktopForYouStripLayout', () {
    test('keeps four boards on ordinary wide rows', () {
      const availableForFour =
          DesktopForYouStripLayout.minCardWidth * 4 +
          DesktopForYouStripLayout.gap * 3;

      final layout = DesktopForYouStripLayout.compute(
        available: availableForFour,
        gameCount: 5,
      );

      expect(layout.visibleCount, 4);
      expect(layout.cardWidth, DesktopForYouStripLayout.minCardWidth);
    });

    test('allows a fifth board when the row is wide enough', () {
      const availableForFive =
          DesktopForYouStripLayout.minCardWidth * 5 +
          DesktopForYouStripLayout.gap * 4;

      final layout = DesktopForYouStripLayout.compute(
        available: availableForFive,
        gameCount: 5,
      );

      expect(layout.visibleCount, 5);
      expect(layout.cardWidth, DesktopForYouStripLayout.minCardWidth);
    });

    test('caps board width instead of stretching across ultra-wide rows', () {
      final layout = DesktopForYouStripLayout.compute(
        available: 1800,
        gameCount: 5,
      );

      expect(layout.visibleCount, 5);
      expect(layout.cardWidth, DesktopForYouStripLayout.maxCardWidth);
    });
  });

  test(
    'For You preview stays on the latest round while board context keeps every round',
    () {
      final round1 = _game('game-1', round: 1);
      final round9 = _game('game-9', round: 9);
      final upcomingRound10 = _game(
        'game-10',
        round: 10,
        status: GameStatus.unknown,
      );

      final context = buildDesktopForYouGameContext(
        snapshotGames: [round9],
        fullVisibleGames: [round1, round9],
        fullEventGames: [round1, round9, upcomingRound10],
      );

      expect(context.stripGames.map((game) => game.roundId), ['round-9']);
      expect(context.boardGames.map((game) => game.roundId), [
        'round-1',
        'round-9',
        'round-10',
      ]);
    },
  );

  test('ordinary For You previews never backfill an older round', () {
    final games = [
      _game('r6-g1', round: 6),
      _game('r6-g2', round: 6),
      _game('r5-g1', round: 5),
      _game('r5-g2', round: 5),
    ];

    final selected = selectDesktopForYouPreviewRoundGames(games);

    expect(selected.map((game) => game.gameId), ['r6-g1', 'r6-g2']);
  });

  test('two-player matches backfill up to three recent rounds', () {
    final games = [
      _matchGame('match-r6', round: 6),
      _matchGame('match-r5', round: 5),
      _matchGame('match-r4', round: 4),
      _matchGame('match-r3', round: 3),
    ];

    final selected = selectDesktopForYouPreviewRoundGames(games);

    expect(selected.map((game) => game.gameId), [
      'match-r6',
      'match-r5',
      'match-r4',
    ]);
    expect(
      desktopForYouBackfillRoundLabel(
        game: selected.first,
        currentGame: selected.first,
      ),
      isNull,
    );
    expect(
      desktopForYouBackfillRoundLabel(
        game: selected[1],
        currentGame: selected.first,
      ),
      'R5',
    );
  });
}

GamesTourModel _game(
  String gameId, {
  required int round,
  GameStatus status = GameStatus.whiteWins,
}) {
  return GamesTourModel(
    gameId: gameId,
    whitePlayer: _player('White $round'),
    blackPlayer: _player('Black $round'),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-$round',
    roundSlug: 'round-$round',
    tourId: 'tour-1',
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: 0,
    countryCode: '',
    team: null,
  );
}

GamesTourModel _matchGame(String gameId, {required int round}) {
  return GamesTourModel(
    gameId: gameId,
    whitePlayer: _player(round.isEven ? 'Player A' : 'Player B'),
    blackPlayer: _player(round.isEven ? 'Player B' : 'Player A'),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.whiteWins,
    roundId: 'round-$round',
    roundSlug: 'round-$round',
    tourId: 'match-tour',
  );
}
