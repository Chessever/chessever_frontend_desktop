import 'package:chessever/desktop/widgets/official_player_result_row.dart';
import 'package:chessever/services/official_round_results.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const result = OfficialRoundResult(
  playerName: 'Player',
  playerFideId: '1',
  roundId: 'r2',
  roundName: 'Round 2',
  roundNumber: 2,
  tourId: 'tour',
  color: 'black',
  points: .5,
  opponentName: 'Opponent',
  opponentTitle: 'GM',
  opponentRating: 2500,
);
Widget wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(body: Center(child: SizedBox(width: 420, child: child))),
  ),
);
void main() {
  testWidgets(
    'keyboard traversal exposes tooltip then Enter explains and Tab clears inline hint',
    (tester) async {
      final before = FocusNode();
      await tester.pumpWidget(
        wrap(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                focusNode: before,
                onPressed: () {},
                child: const Text('Before'),
              ),
              const OfficialPlayerResultRow(result: result),
              TextButton(onPressed: () {}, child: const Text('After')),
            ],
          ),
        ),
      );
      before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Only the result is available.'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(OfficialPlayerResultRow),
          matching: find.text('Only the result is available.'),
        ),
        findsWidgets,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Only the result is available.'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      before.dispose();
    },
  );
  testWidgets('whole official row hover explains with the project tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const OfficialPlayerResultRow(result: result)),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(tester.getCenter(find.text('Opponent')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Only the result is available.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets(
    'blank row activation and Space explain result; changing outcome clears stale hint',
    (tester) async {
      await tester.pumpWidget(
        wrap(const OfficialPlayerResultRow(result: result)),
      );
      final rect = tester.getRect(find.byType(OfficialPlayerResultRow));
      await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
      await tester.pump();
      expect(find.text('Only the result is available.'), findsOneWidget);
      await tester.pumpWidget(
        wrap(
          const OfficialPlayerResultRow(
            result: OfficialRoundResult(
              playerName: 'Player',
              roundId: 'bye',
              roundName: 'Round 3',
              roundNumber: 3,
              points: 1,
              opponentName: 'Bye',
              nonPlayed: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Only the result is available.'), findsNothing);
      expect(find.text('1 NP'), findsOneWidget);
      expect(find.text('2500'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.text('Only the result is available.'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
  testWidgets(
    'bye has no fake opponent profile even if a callback is supplied',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        wrap(
          OfficialPlayerResultRow(
            result: const OfficialRoundResult(
              playerName: 'Player',
              roundId: 'bye',
              roundName: 'Round 3',
              roundNumber: 3,
              points: 1,
              opponentName: 'Bye',
              nonPlayed: true,
            ),
            onOpenOpponent: () => opened++,
          ),
        ),
      );
      await tester.tap(find.text('Bye'));
      expect(opened, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
  testWidgets(
    'result activation explains inline; outside tap and keyboard focus exit clear it',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const OfficialPlayerResultRow(result: result),
              TextButton(onPressed: () {}, child: const Text('Outside')),
            ],
          ),
        ),
      );
      final badge = find.text('½');
      await tester.tap(badge);
      await tester.pump();
      expect(find.text('Only the result is available.'), findsOneWidget);
      await tester.tap(find.text('Outside'));
      await tester.pump();
      expect(find.text('Only the result is available.'), findsNothing);
      tester
          .widget<Focus>(
            find
                .descendant(
                  of: find.byType(OfficialPlayerResultRow),
                  matching: find.byType(Focus),
                )
                .first,
          )
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Only the result is available.'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Only the result is available.'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
  testWidgets(
    'official row is quiet result-only data with a separate opponent action',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        wrap(
          OfficialPlayerResultRow(
            result: result,
            ratingChange: 2,
            onOpenOpponent: () => opened++,
          ),
        ),
      );
      expect(find.text('Opponent'), findsOneWidget);
      expect(find.text('GM'), findsOneWidget);
      expect(find.text('2500'), findsOneWidget);
      expect(find.text('½'), findsOneWidget);
      expect(find.text('R2'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('Only the result is available.'), findsNothing);
      await tester.tap(find.text('Opponent'));
      expect(opened, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
