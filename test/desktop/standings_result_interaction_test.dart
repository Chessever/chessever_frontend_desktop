import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/widgets/tournament_standings_view.dart';

void main() {
  testWidgets('conflicting records disclose conflict without opening a board', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StandingsRoundResult(
              cell: const TournamentStandingsRoundCell.conflicted(round: 5),
              onOpen: () => opens++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('?'), findsOneWidget);
    await tester.tap(find.text('?'));
    await tester.pumpAndSettle();
    expect(opens, 0);
    expect(
      find.text('Conflicting game records for this round.'),
      findsOneWidget,
    );
    expect(find.text('Only the result is available.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'result-only standings activation discloses availability without opening a board',
    (tester) async {
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: StandingsRoundResult(
                cell: const TournamentStandingsRoundCell(
                  game: null,
                  round: 2,
                  resultText: '½',
                  playedWhite: true,
                  opponentName: 'Opponent',
                  opponentRank: 15,
                  opponentRating: 1646,
                  opponentTitle: 'FM',
                  opponentFed: 'MGL',
                  isOngoing: false,
                ),
                onOpen: () => opens++,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Only the result is available.'), findsNothing);
      await tester.tap(find.text('½'));
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(find.text('Only the result is available.'), findsOneWidget);
      expect(find.text('FM'), findsOneWidget);
      expect(find.text('Opponent'), findsOneWidget);
      expect(find.text('#15'), findsOneWidget);
      expect(find.text('(1646)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
