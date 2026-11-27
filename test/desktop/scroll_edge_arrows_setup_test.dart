import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_events_pane.dart';
import 'package:chessever/desktop/services/play/play_tournament_history_repository.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/widgets/play_setup_layout.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';

Widget _cards(int count, {double height = 100}) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  mainAxisSize: MainAxisSize.min,
  children: [
    for (var i = 0; i < count; i++)
      SizedBox(height: height, child: Text('card $i')),
  ],
);

/// The right setup column: a loose scroll above a docked bar.
Widget _rightColumn(Widget cards) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 400,
      height: 500,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: PlaySetupColumnScroll(child: cards)),
          const SizedBox(key: ValueKey('bar'), height: 60),
        ],
      ),
    ),
  ),
);

Finder get _down => find.byIcon(Icons.keyboard_arrow_down_rounded);
Finder get _up => find.byIcon(Icons.keyboard_arrow_up_rounded);

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  testWidgets('a short setup column keeps the bar under its last card', (
    tester,
  ) async {
    await tester.pumpWidget(_rightColumn(_cards(2)));
    await tester.pump();
    expect(tester.getSize(find.byType(PlaySetupColumnScroll)).height, 200);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('bar'))).dy -
          tester.getTopLeft(find.byType(PlaySetupColumnScroll)).dy,
      200,
    );
    expect(find.byType(RawScrollbar), findsNothing);
    expect(_down, findsNothing);
    expect(_up, findsNothing);
  });

  testWidgets('a tall setup column scrolls by its arrow, not a scrollbar', (
    tester,
  ) async {
    await tester.pumpWidget(_rightColumn(_cards(8)));
    await tester.pump();
    expect(tester.getSize(find.byType(PlaySetupColumnScroll)).height, 440);
    expect(find.byType(RawScrollbar), findsNothing);
    expect(_up, findsNothing);
    expect(_down, findsOneWidget);

    await tester.tap(_down);
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(440 * 0.8, 0.5));
    expect(_up, findsOneWidget);
  });

  testWidgets('a column that grows or shrinks refits its height', (
    tester,
  ) async {
    final count = ValueNotifier(2);
    await tester.pumpWidget(
      _rightColumn(
        ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (context, n, _) => _cards(n),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(PlaySetupColumnScroll)).height, 200);

    count.value = 3;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(PlaySetupColumnScroll)).height, 300);

    count.value = 1;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(PlaySetupColumnScroll)).height, 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stacked setup page shows an arrow and no scrollbar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PlaySetupPage(
          title: 'Play vs bot',
          subtitle: 'Choose a bot',
          left: [SizedBox(height: 400, child: Text('left'))],
          right: [SizedBox(height: 400, child: Text('right'))],
          startBar: const SizedBox(height: 60),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ScrollEdgeArrows), findsOneWidget);
    expect(find.byType(RawScrollbar), findsNothing);
    expect(_down, findsOneWidget);

    await tester.tap(_down);
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, greaterThan(0));
    expect(_up, findsOneWidget);
  });

  testWidgets('the events list scrolls by its arrow, not a scrollbar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 11, 1);
    final events = [
      for (var i = 0; i < 12; i++)
        PlayedTournamentEvent(
          id: 'e$i',
          title: 'Event $i',
          format: TournamentFormat.roundRobin,
          status: PlayedTournamentStatus.completed,
          createdAt: now,
          updatedAt: now,
          completedAt: now,
          participantCount: 4,
          gameCount: 6,
          finishedGameCount: 6,
          userGameCount: 3,
          userFinishedGameCount: 3,
          userScore: 1.5,
        ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playedTournamentEventsProvider.overrideWith((ref) async => events),
        ],
        child: const MaterialApp(home: Scaffold(body: PlayEventsPane())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Event 0'), findsOneWidget);
    expect(find.byType(RawScrollbar), findsNothing);
    expect(_up, findsNothing);
    expect(_down, findsOneWidget);

    await tester.tap(_down);
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(400, 0.5));
    expect(_up, findsOneWidget);
  });
}
