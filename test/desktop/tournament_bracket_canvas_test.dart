import 'package:chessever/desktop/widgets/tournament_bracket_canvas.dart';
import 'package:chessever/screens/tour_detail/bracket/models/knockout_bracket.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('renders Desktop stage columns and activates a match card', (
    tester,
  ) async {
    final bracket = _bracket();
    KnockoutMatch? activated;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 600,
              child: DesktopKnockoutBracketCanvas(
                bracket: bracket,
                onMatchActivate: (match) => activated = match,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Quarterfinals'), findsOneWidget);
    expect(find.text('Semifinals'), findsOneWidget);
    expect(find.text('Alpha'), findsNWidgets(2));
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('1.5'), findsOneWidget);
    expect(find.text('0.5'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('desktop-bracket-match-quarter-alpha-beta')),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(activated?.key, 'quarter-alpha-beta');
  });
}

KnockoutBracket _bracket() {
  const alpha = BracketParticipant(
    id: 'alpha',
    name: 'Alpha',
    federation: 'USA',
    title: 'GM',
    rating: 2700,
  );
  const beta = BracketParticipant(
    id: 'beta',
    name: 'Beta',
    federation: 'FRA',
    title: 'GM',
    rating: 2650,
  );
  const gamma = BracketParticipant(
    id: 'gamma',
    name: 'Gamma',
    federation: 'IND',
    title: 'GM',
    rating: 2660,
  );
  final quarter = KnockoutMatch(
    key: 'quarter-alpha-beta',
    stageKey: 'quarterfinals',
    participant1: alpha,
    participant2: beta,
    games: const [],
    participant1Score: 1.5,
    participant2Score: 0.5,
    leader: alpha,
    winner: alpha,
    minimumBoardOrder: 1,
    isComplete: true,
    isLive: false,
  );
  final semi = KnockoutMatch(
    key: 'semi-alpha-gamma',
    stageKey: 'semifinals',
    participant1: alpha,
    participant2: gamma,
    games: const [],
    participant1Score: 0,
    participant2Score: 0,
    leader: null,
    winner: null,
    minimumBoardOrder: 1,
    isComplete: false,
    isLive: true,
  );
  return KnockoutBracket(
    stages: [
      KnockoutStage(
        key: 'quarterfinals',
        label: 'Quarterfinals',
        sourceTourIds: const ['tour'],
        sourceRoundIds: const ['qf'],
        order: 0,
        state: KnockoutStageState.completed,
        isLive: false,
        matches: [quarter],
      ),
      KnockoutStage(
        key: 'semifinals',
        label: 'Semifinals',
        sourceTourIds: const ['tour'],
        sourceRoundIds: const ['sf'],
        order: 1,
        state: KnockoutStageState.inProgress,
        isLive: true,
        matches: [semi],
      ),
    ],
    edges: const [
      KnockoutEdge(
        sourceMatchKey: 'quarter-alpha-beta',
        destinationMatchKey: 'semi-alpha-gamma',
        participantId: 'alpha',
      ),
    ],
    selectedStageKey: 'quarterfinals',
    currentStageKey: 'semifinals',
    isPartial: false,
  );
}
