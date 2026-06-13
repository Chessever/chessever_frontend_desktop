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
      '—',
    );
  });

  test(
    'uses profile federation fallback for placeholder profile-player rows',
    () {
      expect(
        defaultGamePlayerFederation(
          _player('Elber Zhu', federation: 'FID', fideId: 2620965),
          profilePlayerName: 'Elber Zhu',
          profilePlayerFideId: 2620965,
          profileFederationFallback: 'CAN',
        ),
        'CAN',
      );
      expect(
        defaultGamePlayerFederation(
          _player('Zhu, Elber', federation: '', countryCode: '', fideId: 0),
          profilePlayerName: 'Elber Zhu',
          profileFederationFallback: 'CAN',
        ),
        'CAN',
      );
      expect(
        defaultGamePlayerFederation(
          _player('Different Player', federation: 'FID', fideId: 0),
          profilePlayerName: 'Elber Zhu',
          profileFederationFallback: 'CAN',
        ),
        'FID',
      );
    },
  );

  testWidgets('table renders profile federation fallback flag', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _wrap(
        controller: controller,
        onOpen: (_) {},
        games: [
          _game(
            0,
            whitePlayer: _player(
              'Elber Zhu',
              federation: 'FID',
              fideId: 2620965,
            ),
            blackPlayer: _player('Opponent', federation: '', countryCode: ''),
          ),
        ],
        profilePlayerName: 'Elber Zhu',
        profilePlayerFideId: 2620965,
        profileFederationFallback: 'CAN',
      ),
    );
    await tester.pump();

    expect(find.byType(FederationFlag), findsOneWidget);
    final flag = tester.widget<FederationFlag>(find.byType(FederationFlag));
    expect(flag.federation, 'CA');
  });

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
  List<GamesTourModel>? games,
  String? profilePlayerName,
  int? profilePlayerFideId,
  String? profileFederationFallback,
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
            onOpenGame: (game, {required bool inNewTab}) => onOpen(game),
            profilePlayerName: profilePlayerName,
            profilePlayerFideId: profilePlayerFideId,
            profileFederationFallback: profileFederationFallback,
          ),
        ),
      ),
    ),
  );
}

GamesTourModel _game(
  int index, {
  PlayerCard? whitePlayer,
  PlayerCard? blackPlayer,
}) {
  return GamesTourModel(
    gameId: 'game-$index',
    whitePlayer: whitePlayer ?? _player('White$index'),
    blackPlayer: blackPlayer ?? _player('Black$index'),
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
  String countryCode = 'USA',
  int fideId = 0,
}) {
  return PlayerCard(
    name: name,
    federation: federation,
    title: 'GM',
    rating: 2600,
    fideId: fideId,
    countryCode: countryCode,
    team: null,
  );
}
