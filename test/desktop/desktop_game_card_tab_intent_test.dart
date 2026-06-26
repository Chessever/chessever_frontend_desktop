import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/date_time_provider.dart';

void main() {
  testWidgets('Command-click opens a draggable game card in a background tab', (
    tester,
  ) async {
    var foregroundOpens = 0;
    final spawnedFocusValues = <bool>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: _cardProviderOverrides(),
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
        overrides: _cardProviderOverrides(),
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
      ProviderScope(
        overrides: _cardProviderOverrides(),
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

  testWidgets('started live list card does not reserve dash result badges', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _cardProviderOverrides(),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 160,
              child: DesktopGameCard(
                data: _startedLiveDataWithClocks,
                layout: DesktopCardLayout.list,
                onTap: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('–'), findsNothing);
    expect(find.text('-'), findsNothing);
  });

  testWidgets('started live grid card does not reserve dash result badges', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _cardProviderOverrides(),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 360,
              child: DesktopGameCard(
                data: _startedLiveDataWithClocks,
                layout: DesktopCardLayout.grid,
                onTap: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('–'), findsNothing);
    expect(find.text('-'), findsNothing);
    expect(find.text('12:34'), findsOneWidget);
    expect(find.text('23:45'), findsOneWidget);
  });

  testWidgets('grid game card does not depress before opening', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _cardProviderOverrides(),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 360,
              child: DesktopGameCard(
                data: _startedLiveDataWithClocks,
                layout: DesktopCardLayout.grid,
                onTap: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.widget<MotionCard>(find.byType(MotionCard)).depressOnPress,
      isFalse,
    );
  });

  testWidgets('running live clock uses the primary color', (tester) async {
    final data = _startedLiveDataWithClocks.copyWithRunningClock(
      activePlayer: Side.white,
      lastMoveTime: DateTime.now(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: _cardProviderOverrides(clockNow: data.lastMoveTime),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 360,
              child: DesktopGameCard(
                data: data,
                layout: DesktopCardLayout.grid,
                onTap: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    final activeClock = tester.widget<Text>(find.text('12:34'));
    final inactiveClock = tester.widget<Text>(find.text('23:45'));

    expect(activeClock.style?.color, kPrimaryColor);
    expect(inactiveClock.style?.color, kWhiteColor70);
  });

  testWidgets('finished compact card keeps normal game-view result text', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _cardProviderOverrides(),
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

List<Override> _cardProviderOverrides({DateTime? clockNow}) {
  return [
    boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
    engineSettingsProviderNew.overrideWith(_TestEngineSettingsNotifier.new),
    if (clockNow != null)
      dateTimeProvider.overrideWith((ref) => Stream.value(clockNow)),
  ];
}

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

const _startedLiveDataWithClocks = GameCardData(
  id: 'game-live-clocks',
  title: 'White vs Black',
  whiteName: 'White',
  blackName: 'Black',
  whiteFederation: '',
  blackFederation: '',
  whiteTitle: '',
  blackTitle: '',
  whiteRating: 2221,
  blackRating: 2380,
  fen: null,
  status: GameStatus.ongoing,
  hasStarted: true,
  whiteClockSeconds: 754,
  blackClockSeconds: 1425,
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

extension on GameCardData {
  GameCardData copyWithRunningClock({
    required Side activePlayer,
    required DateTime lastMoveTime,
  }) {
    return GameCardData(
      id: id,
      title: title,
      whiteName: whiteName,
      blackName: blackName,
      whiteFederation: whiteFederation,
      blackFederation: blackFederation,
      whiteTitle: whiteTitle,
      blackTitle: blackTitle,
      whiteRating: whiteRating,
      blackRating: blackRating,
      whiteFideId: whiteFideId,
      blackFideId: blackFideId,
      fen: fen,
      status: status,
      hasStarted: hasStarted,
      lastMove: lastMove,
      openingName: openingName,
      subtitle: subtitle,
      whiteClockSeconds: whiteClockSeconds,
      blackClockSeconds: blackClockSeconds,
      whiteClockCentiseconds: whiteClockCentiseconds,
      blackClockCentiseconds: blackClockCentiseconds,
      lastMoveTime: lastMoveTime,
      activePlayer: activePlayer,
      canResolveRemoteFen: canResolveRemoteFen,
    );
  }
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew();
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _TestEngineSettingsNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings();
    state = const AsyncValue.data(settings);
    return settings;
  }
}
