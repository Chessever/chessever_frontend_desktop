import 'dart:async';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/utils/date_time_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A broadcast row that exists before the first move: the relay puts the time
/// control in `last_clock_*` (3:02 for a 3+2 game). It may be shown as a static
/// starting value, but it must never tick before the game starts.
Map<String, dynamic> _preStartRow({
  int? thinkTime,
  int whiteClock = 18200,
  int blackClock = 18200,
}) => <String, dynamic>{
  'id': 'PZVPubQ9',
  'round_id': 'TpN6PqHz',
  'round_slug': 'round-5',
  'tour_id': 'WbAxpbqH',
  'tour_slug': 'total-chess-world-championship-tour-pilot-2026-blitz-tiebreak',
  'board_nr': 8,
  'last_move': null,
  'last_move_time': null,
  'last_clock_white': whiteClock == 0 ? null : 182,
  'last_clock_black': blackClock == 0 ? null : 182,
  'think_time': thinkTime,
  'status': '*',
  'players': <Map<String, dynamic>>[
    <String, dynamic>{
      'fed': 'ARM',
      'name': 'Martirosyan, Haik M.',
      'clock': whiteClock,
      'title': 'GM',
      'fideId': 13306553,
      'rating': 2686,
    },
    <String, dynamic>{
      'fed': 'AZE',
      'name': 'Mamedyarov, Shakhriyar',
      'clock': blackClock,
      'title': 'GM',
      'fideId': 13401319,
      'rating': 2612,
    },
  ],
  'time_start': '18:15:35',
  'date_start': '2026-11-10',
  'fen': null,
  'pgn': null,
};

void main() {
  test(
    'a not-started broadcast row keeps a static time control, no anchor',
    () {
      final model = GamesTourModel.fromGame(Games.fromJson(_preStartRow()));

      expect(model.hasStarted, isFalse);
      expect(model.whiteTimeDisplay, '03:02');
      expect(model.blackTimeDisplay, '03:02');
      expect(model.whiteClockSeconds, 182);
      expect(model.blackClockSeconds, 182);
      // The scheduled date is not a last-move anchor: a synthetic midnight
      // anchor is what made the pre-start clock count down to 00:00.
      expect(model.lastMoveTime, isNull);
    },
  );

  test('think_time never becomes a pre-start clock reading', () {
    // `think_time` is elapsed time, not remaining time. Broadcast rows have
    // carried arbitrary values here; 10800 is exactly the reported "3 hours".
    final model = GamesTourModel.fromGame(
      Games.fromJson(
        _preStartRow(thinkTime: 10800, whiteClock: 0, blackClock: 0),
      ),
    );

    expect(model.whiteTimeDisplay, '--:--');
    expect(model.blackTimeDisplay, '--:--');
    expect(model.whiteClockSeconds, isNull);
    expect(model.blackClockSeconds, isNull);
    expect(model.lastMoveTime, isNull);
  });

  test('a pre-start 3+2 row keeps its 3:02 control when think_time is set', () {
    // The Total Chess board that read 3:00:02 before the first move: the relay
    // published `think_time` 10802 (3h 0m 2s of elapsed thinking budget) next
    // to the real 3+2 control in `players[].clock` (18200 centiseconds) and no
    // `last_clock_*` reading. Only the control may reach the badge.
    final row = _preStartRow(thinkTime: 10802, whiteClock: 18200);
    row.remove('last_clock_white');
    row.remove('last_clock_black');
    final model = GamesTourModel.fromGame(Games.fromJson(row));

    expect(model.hasStarted, isFalse);
    expect(model.whiteTimeDisplay, '03:02');
    expect(model.blackTimeDisplay, '03:02');
    expect(model.whiteClockSeconds, 182);
    expect(model.blackClockSeconds, 182);
    expect(model.lastMoveTime, isNull);
  });

  testWidgets('the board header does not tick a clock before the first move', (
    tester,
  ) async {
    // Same Total Chess 3+2 row as the report: `think_time` 10802 must not win
    // over the 3:02 control, and the badge must stay at 03:02 until move one.
    final row = _preStartRow(thinkTime: 10802);
    row.remove('last_clock_white');
    row.remove('last_clock_black');
    final model = GamesTourModel.fromGame(Games.fromJson(row));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          baseGameProvider(model.gameId).overrideWith((ref) => model),
          dateTimeProvider.overrideWith(
            (ref) => Stream<DateTime>.value(DateTime.now()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DesktopBoardPlayerHeader(
              name: 'Martirosyan, Haik M.',
              federation: 'ARM',
              title: 'GM',
              rating: 2686,
              fideId: null,
              result: null,
              isWhite: true,
              isToMove: true,
              clockText: model.whiteTimeDisplay,
              useLiveClock: true,
              activeGameId: model.gameId,
              sourceGame: model,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Initial control is visible, but the synthetic midnight anchor is gone:
    // the clock does not run down to 00:00 while the game waits to start.
    expect(find.text('03:02'), findsOneWidget);
    expect(find.text('00:00'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('03:02'), findsOneWidget);
  });

  testWidgets('a future move anchor does not consume clock time', (
    tester,
  ) async {
    final row = _preStartRow();
    row['last_move'] = 'e2e4';
    row['last_move_time'] =
        DateTime.now().toUtc().add(const Duration(hours: 3)).toIso8601String();
    row['last_clock_white'] = 10800;
    row['last_clock_black'] = 10800;
    final model = GamesTourModel.fromGame(Games.fromJson(row));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          baseGameProvider(model.gameId).overrideWith((ref) => model),
          dateTimeProvider.overrideWith(
            (ref) => Stream<DateTime>.value(DateTime.now()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DesktopBoardPlayerHeader(
              name: 'Martirosyan, Haik M.',
              federation: 'ARM',
              title: 'GM',
              rating: 2686,
              fideId: null,
              result: null,
              isWhite: true,
              isToMove: true,
              clockText: model.whiteTimeDisplay,
              useLiveClock: true,
              activeGameId: model.gameId,
              sourceGame: model,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3:00:00'), findsOneWidget);
    expect(find.text('00:00'), findsNothing);
  });
}
