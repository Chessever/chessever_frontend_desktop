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
}
