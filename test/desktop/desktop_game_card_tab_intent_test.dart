import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  testWidgets('Command-click opens a draggable game card in a background tab', (
    tester,
  ) async {
    var foregroundOpens = 0;
    final spawnedFocusValues = <bool>[];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DesktopGameCard(
              data: _data,
              layout: DesktopCardLayout.compact,
              onTap: () => foregroundOpens++,
              dragPayload: GameTabDragPayload(
                id: _data.id,
                label: _data.title,
                spawn: (_, {required focus}) async {
                  spawnedFocusValues.add(focus);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.byType(DesktopGameCard));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);

    expect(foregroundOpens, 0);
    expect(spawnedFocusValues, <bool>[false]);
  });

  testWidgets('plain click keeps the existing foreground open behavior', (
    tester,
  ) async {
    var foregroundOpens = 0;
    final spawnedFocusValues = <bool>[];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DesktopGameCard(
              data: _data,
              layout: DesktopCardLayout.compact,
              onTap: () => foregroundOpens++,
              dragPayload: GameTabDragPayload(
                id: _data.id,
                label: _data.title,
                spawn: (_, {required focus}) async {
                  spawnedFocusValues.add(focus);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DesktopGameCard));

    expect(foregroundOpens, 1);
    expect(spawnedFocusValues, isEmpty);
  });

  testWidgets('started live compact card leaves result slot empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DesktopGameCard(
              data: _startedLiveData,
              layout: DesktopCardLayout.compact,
              onTap: _noop,
            ),
          ),
        ),
      ),
    );

    expect(find.text('—'), findsNothing);
    expect(find.text('-'), findsNothing);
    expect(find.text('vs'), findsNothing);
  });

  testWidgets('finished compact card keeps normal game-view result text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DesktopGameCard(
              data: _finishedData,
              layout: DesktopCardLayout.compact,
              onTap: _noop,
            ),
          ),
        ),
      ),
    );

    expect(find.text('1 – 0'), findsOneWidget);
  });
}

void _noop() {}

const _data = GameCardData(
  id: 'game-1',
  title: 'White vs Black',
  whiteName: 'White',
  blackName: 'Black',
  whiteFederation: '',
  blackFederation: '',
  whiteTitle: '',
  blackTitle: '',
  whiteRating: 0,
  blackRating: 0,
  fen: null,
  status: GameStatus.ongoing,
  hasStarted: false,
);

const _startedLiveData = GameCardData(
  id: 'game-live',
  title: 'White vs Black',
  whiteName: 'White',
  blackName: 'Black',
  whiteFederation: '',
  blackFederation: '',
  whiteTitle: '',
  blackTitle: '',
  whiteRating: 0,
  blackRating: 0,
  fen: null,
  status: GameStatus.ongoing,
  hasStarted: true,
);

const _finishedData = GameCardData(
  id: 'game-finished',
  title: 'White vs Black',
  whiteName: 'White',
  blackName: 'Black',
  whiteFederation: '',
  blackFederation: '',
  whiteTitle: '',
  blackTitle: '',
  whiteRating: 0,
  blackRating: 0,
  fen: null,
  status: GameStatus.whiteWins,
  hasStarted: true,
);
