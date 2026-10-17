import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets(
    'one recorded side does not create a clock for the other player',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  DesktopBoardPlayerHeader(
                    name: 'Player One',
                    federation: 'USA',
                    title: 'IM',
                    rating: 2000,
                    fideId: null,
                    result: null,
                    isWhite: true,
                    isToMove: false,
                    clockText: '12:34',
                  ),
                  DesktopBoardPlayerHeader(
                    name: 'Player Two',
                    federation: 'USA',
                    title: 'IM',
                    rating: 2000,
                    fideId: null,
                    result: null,
                    isWhite: false,
                    isToMove: true,
                    clockText: '--:--',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('12:34'), findsOneWidget);
      expect(find.text('--:--'), findsNothing);
      expect(
        find.byKey(const Key('desktop-board-clock-segment')),
        findsOneWidget,
      );
      expect(find.text('Player Two'), findsOneWidget);
    },
  );
  for (final placeholder in ['--:--', '-:--:--', '-']) {
    testWidgets('static header omits missing clock $placeholder', (
      tester,
    ) async {
      await tester.pumpWidget(_app(clock: placeholder));
      await tester.pumpAndSettle();
      expect(find.text(placeholder), findsNothing);
      expect(
        find.byKey(const Key('desktop-board-clock-segment')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('desktop-board-result-clock-capsule')),
        findsNothing,
      );
      expect(find.text('Player One'), findsOneWidget);
      expect(find.text('(2000)'), findsOneWidget);
    });
  }
  testWidgets('result remains without a placeholder clock', (tester) async {
    await tester.pumpWidget(
      _app(clock: '--:--', result: DesktopBoardPlayerResult.won),
    );
    await tester.pumpAndSettle();
    expect(find.text('WON'), findsOneWidget);
    expect(find.text('--:--'), findsNothing);
    expect(find.byKey(const Key('desktop-board-clock-segment')), findsNothing);
    expect(
      find.byKey(const Key('desktop-board-result-clock-capsule')),
      findsOneWidget,
    );
  });
  for (final clock in ['12:34', '00:00']) {
    testWidgets('recorded clock $clock stays visible', (tester) async {
      await tester.pumpWidget(_app(clock: clock));
      await tester.pumpAndSettle();
      expect(find.text(clock), findsOneWidget);
      expect(
        find.byKey(const Key('desktop-board-clock-segment')),
        findsOneWidget,
      );
    });
  }
  testWidgets('live timestamp alone does not invent a zero clock', (
    tester,
  ) async {
    final game = _source(seconds: null, stamp: DateTime.utc(2026, 10, 10));
    await tester.pumpWidget(_app(clock: '--:--', live: true, source: game));
    await tester.pumpAndSettle();
    expect(find.text('00:00'), findsNothing);
    expect(find.byKey(const Key('desktop-board-clock-segment')), findsNothing);
  });
  for (final seconds in [0, 754]) {
    testWidgets('real live seconds $seconds remain without a timestamp', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(clock: '--:--', live: true, source: _source(seconds: seconds)),
      );
      await tester.pumpAndSettle();
      expect(find.text(seconds == 0 ? '00:00' : '12:34'), findsOneWidget);
      expect(find.text('--:--'), findsNothing);
    });
  }
  testWidgets(
    'live mode keeps a valid recorded fallback when snapshot is missing',
    (tester) async {
      await tester.pumpWidget(_app(clock: '12:34', live: true));
      await tester.pumpAndSettle();
      expect(find.text('12:34'), findsOneWidget);
    },
  );
}

Widget _app({
  String? clock,
  DesktopBoardPlayerResult? result,
  bool live = false,
  GamesTourModel? source,
}) => ProviderScope(
  overrides: [
    baseGameProvider('missing-clock-test').overrideWith((ref) => source),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 760,
        height: 48,
        child: DesktopBoardPlayerHeader(
          name: 'Player One',
          federation: 'USA',
          title: 'IM',
          rating: 2000,
          fideId: null,
          result: result,
          isWhite: true,
          isToMove: false,
          clockText: clock,
          useLiveClock: live,
          activeGameId: live ? 'missing-clock-test' : null,
          sourceGame: source,
        ),
      ),
    ),
  ),
);

GamesTourModel _source({int? seconds, DateTime? stamp}) => GamesTourModel(
  gameId: 'missing-clock-test',
  whitePlayer: PlayerCard(
    name: 'Player One',
    federation: 'USA',
    title: 'IM',
    rating: 2000,
    countryCode: 'USA',
    team: null,
  ),
  blackPlayer: PlayerCard(
    name: 'Player Two',
    federation: 'USA',
    title: 'IM',
    rating: 2000,
    countryCode: 'USA',
    team: null,
  ),
  whiteTimeDisplay: '--:--',
  blackTimeDisplay: '--:--',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  whiteClockSeconds: seconds,
  blackClockSeconds: null,
  lastMoveTime: stamp,
  gameStatus: GameStatus.unknown,
  roundId: '',
  tourId: '',
);
