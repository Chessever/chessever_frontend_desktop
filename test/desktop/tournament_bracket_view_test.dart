import 'package:chessever/desktop/widgets/tournament_bracket_view.dart';
import 'package:chessever/screens/tour_detail/bracket/models/knockout_bracket.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets(
    'hosts the bracket with controls and a responsive match inspector',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(760, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: DesktopTournamentBracketViewport(
                bracket: _bracket(),
                cameraKey: 'tab::tour',
                onOpenGame: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('bracket-fit-button')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bracket-current-stage-button')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const ValueKey('desktop-bracket-match-quarter-alpha-beta')),
      );
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Match details'), findsOneWidget);
      expect(find.text('Alpha vs Beta'), findsOneWidget);
      expect(
        find.text('No game legs have been published yet.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows honest loading, empty, and retryable error states', (
    tester,
  ) async {
    var retries = 0;

    Future<void> pump(AsyncValue<KnockoutBracket> state) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DesktopTournamentBracketContent(
              state: state,
              cameraKey: 'tab::tour',
              onRetry: () => retries += 1,
              onOpenGame: (_) {},
            ),
          ),
        ),
      ),
    );

    await pump(const AsyncValue.loading());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await pump(
      AsyncValue.error(StateError('network unavailable'), StackTrace.current),
    );
    expect(find.text('Bracket could not be loaded'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(retries, 1);

    await pump(
      AsyncValue.data(
        KnockoutBracket(
          stages: [],
          edges: [],
          selectedStageKey: null,
          currentStageKey: null,
          isPartial: false,
        ),
      ),
    );
    expect(find.text('No bracket has been published yet.'), findsOneWidget);

    await pump(
      AsyncValue.data(
        KnockoutBracket(
          stages: [
            KnockoutStage(
              key: 'semifinals',
              label: 'Semifinals',
              sourceTourIds: ['tour'],
              sourceRoundIds: ['sf'],
              order: 0,
              state: KnockoutStageState.upcoming,
              isLive: false,
              matches: [],
            ),
          ],
          edges: const [],
          selectedStageKey: 'semifinals',
          currentStageKey: null,
          isPartial: true,
        ),
      ),
    );
    expect(find.text('No bracket has been published yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('bracket-fit-button')), findsNothing);
  });
}

KnockoutBracket _bracket() {
  const alpha = BracketParticipant(id: 'alpha', name: 'Alpha');
  const beta = BracketParticipant(id: 'beta', name: 'Beta');
  const gamma = BracketParticipant(id: 'gamma', name: 'Gamma');
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
