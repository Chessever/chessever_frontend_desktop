import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/tournament_games_view.dart';

void main() {
  testWidgets('Live filter explains when no games are currently live', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TournamentGamesEmptyState(liveOnly: true)),
      ),
    );

    expect(find.text('No live games right now'), findsOneWidget);
    expect(
      find.text('Switch to All to browse completed and upcoming games.'),
      findsOneWidget,
    );
  });

  testWidgets('Failed tournament feed offers a retry action', (tester) async {
    var retryCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TournamentGamesLoadError(onRetry: () => retryCount++),
        ),
      ),
    );

    expect(find.text('Could not load games'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retryCount, 1);
  });
}
