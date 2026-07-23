import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/default_games_table.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/federation_flag.dart';

void main() {
  test(
    'formats compact table player names as last name plus first initial',
    () {
      expect(defaultGamePlayerName('Sam Shankland'), 'Shankland, S.');
      expect(
        defaultGamePlayerName('Martinez Ramirez, Leandro'),
        'Martinez Ramirez, L.',
      );
      expect(defaultGamePlayerName('IM Fernando Peralta'), 'Peralta, F.');
      expect(defaultGamePlayerName('White0'), 'White0');
    },
  );

  test('round label does not echo ECO codes', () {
    expect(
      defaultGameRoundLabel(
        _game(0).copyWith(roundSlug: 'B48', roundId: 'Round 2'),
      ),
      'Round 2',
    );
    expect(
      defaultGameRoundLabel(
        _game(0).copyWith(roundSlug: 'B48', roundId: 'E90'),
      ),
      '',
    );
  });

  test('missing compact-table metadata is rendered as blank', () {
    final game = GamesTourModel(
      gameId: 'missing-metadata',
      whitePlayer: _player(
        'White',
        federation: '',
        countryCode: '',
        title: '',
        rating: 0,
      ),
      blackPlayer: _player(
        'Black',
        federation: '',
        countryCode: '',
        title: '',
        rating: 0,
      ),
      whiteTimeDisplay: '',
      blackTimeDisplay: '',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: GameStatus.unknown,
      roundId: '?',
      roundSlug: '—',
      tourId: 'library',
      tourSlug: '-',
      eco: '?',
      openingName: 'Unknown',
    );

    expect(defaultGamePlayerName(game.whitePlayer.name), '');
    expect(defaultGamePlayerName(game.blackPlayer.name), '');
    expect(defaultGameEventLabel(game), '');
    expect(defaultGameRoundLabel(game), '');
    expect(defaultGameSite(game), '');
    expect(defaultGameDateLabel(game), '');
    expect(defaultGameResultText(game.gameStatus), '');
  });

  testWidgets('does not paint missing values or placeholders in table rows', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final game = GamesTourModel(
      gameId: 'blank-row',
      whitePlayer: _player(
        'White',
        federation: '',
        countryCode: '',
        title: '',
        rating: 0,
      ),
      blackPlayer: _player(
        'Black',
        federation: '',
        countryCode: '',
        title: '',
        rating: 0,
      ),
      whiteTimeDisplay: '',
      blackTimeDisplay: '',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: GameStatus.unknown,
      roundId: '?',
      tourId: 'library',
      tourSlug: '—',
      eco: '?',
      openingName: 'Unknown opening',
    );

    await tester.pumpWidget(
      _wrap(controller: controller, onOpen: (_) {}, games: [game]),
    );
    await tester.pump();

    for (final placeholder in const [
      '—',
      '–',
      '-',
      '?',
      '*',
      'White',
      'Black',
    ]) {
      expect(find.text(placeholder), findsNothing);
    }
  });

  testWidgets('can hide host-specific metadata columns', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _wrap(
        controller: controller,
        onOpen: (_) {},
        hiddenColumnIds: const {'round', 'site'},
      ),
    );
    await tester.pump();

    expect(find.text('ROUND'), findsNothing);
    expect(find.text('SITE'), findsNothing);
    expect(find.text('EVENT'), findsOneWidget);
    expect(find.text('ECO'), findsOneWidget);
  });

  testWidgets('renders raw FID and FIDE markers as compact-table FIDE flags', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final game = _game(0).copyWith(
      whitePlayer: _player('White FID', federation: 'FID'),
      blackPlayer: _player('Black FIDE', federation: 'FIDE'),
    );

    await tester.pumpWidget(
      _wrap(controller: controller, onOpen: (_) {}, games: [game]),
    );
    await tester.pump();

    final flags = tester.widgetList<FederationFlag>(
      find.byType(FederationFlag),
    );
    expect(flags.map((flag) => flag.federation).toList(), ['FID', 'FIDE']);
  });

  testWidgets(
    'does not reserve a compact-table flag gap for unresolvable federations',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final unknown = _game(0).copyWith(
        whitePlayer: _player(
          'Unknown0',
          federation: 'Atlantis',
          countryCode: 'Atlantis',
        ),
      );
      final empty = _game(1).copyWith(
        whitePlayer: _player('NoFed0', federation: '', countryCode: ''),
      );

      await tester.pumpWidget(
        _wrap(controller: controller, onOpen: (_) {}, games: [unknown, empty]),
      );
      await tester.pump();

      expect(defaultGamePlayerFlagFederation(unknown.whitePlayer), isNull);
      expect(defaultGamePlayerFlagFederation(empty.whitePlayer), isNull);
      expect(
        tester.getTopLeft(find.text('Unknown0')).dx,
        tester.getTopLeft(find.text('NoFed0')).dx,
      );
    },
  );

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

  testWidgets('Ctrl/Cmd click opens the selected game in a new tab', (
    tester,
  ) async {
    final opened = <String>[];
    final openedInNewTabs = <bool>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _wrap(
        controller: controller,
        onOpen: (game) => opened.add(game.gameId),
        onOpenInNewTab: openedInNewTabs.add,
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('White0'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(opened, ['game-0']);
    expect(openedInNewTabs, [true]);
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
  ValueChanged<bool>? onOpenInNewTab,
  List<GamesTourModel>? games,
  bool selectionMode = false,
  Set<String> selectedIds = const <String>{},
  ValueChanged<String>? onToggleSelection,
  ValueChanged<Set<String>>? onReplaceSelection,
  Set<String> hiddenColumnIds = const <String>{},
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
            games: games ?? List.generate(24, _game),
            controller: controller,
            selectionMode: selectionMode,
            selectedIds: selectedIds,
            onToggleSelection: onToggleSelection,
            onReplaceSelection: onReplaceSelection,
            hiddenColumnIds: hiddenColumnIds,
            onOpenGame: (game, {required bool inNewTab}) {
              onOpen(game);
              onOpenInNewTab?.call(inNewTab);
            },
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

PlayerCard _player(
  String name, {
  String federation = 'USA',
  String? countryCode,
  String title = 'GM',
  int rating = 2600,
}) {
  return PlayerCard(
    name: name,
    federation: federation,
    title: title,
    rating: rating,
    countryCode: countryCode ?? federation,
    team: null,
  );
}
