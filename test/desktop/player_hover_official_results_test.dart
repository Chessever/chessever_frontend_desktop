import 'package:chessever/desktop/widgets/player_hover_preview.dart';
import 'package:chessever/desktop/widgets/official_player_result_row.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/screens/tour_detail/official_round_results_provider.dart';
import 'package:chessever/services/official_round_results.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const player = PlayerHoverPreviewIdentity(name: 'Player', fideId: 1);
OfficialRoundResult outcome({
  String id = 'r2',
  String tour = 'tour',
  String fide = '1',
}) => OfficialRoundResult(
  playerName: 'Player',
  playerFideId: fide,
  roundId: id,
  roundName: 'Round 2',
  roundNumber: 2,
  tourId: tour,
  color: 'black',
  points: 1,
  opponentName: 'Missing opponent',
);
OfficialRoundResults round(OfficialRoundResult r) => OfficialRoundResults(
  roundId: r.roundId,
  roundName: r.roundName,
  roundNumber: r.roundNumber,
  tourId: r.tourId,
  results: [r],
);
const game = TournamentGameSummary(
  id: 'real',
  name: '',
  whitePlayer: 'Player',
  whiteFideId: 1,
  blackPlayer: 'Real opponent',
  tourId: 'tour',
  roundId: 'r1',
  roundLabel: '1',
  hasPgn: true,
);
void main() {
  testWidgets(
    'official reads are lazy event-scoped, including zero-game player; failure keeps games',
    (tester) async {
      final reads = <String>[];
      Widget host({bool fail = false, bool zero = false}) => ProviderScope(
        overrides: [
          officialRoundResultsProvider.overrideWith((ref, id) async {
            reads.add(id);
            if (fail) throw StateError('optional unavailable');
            return [round(outcome())];
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerHoverPreview(
                player: player,
                games: zero ? const [] : const [game],
                eventTourIds: zero ? const ['tour'] : const [],
                onOpenOpponentInNewTab: (_) {},
                onOpenGameInNewTab: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(zero: true));
      expect(reads, isEmpty);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      Future<void> open() async {
        await mouse.moveTo(
          tester.getCenter(
            find.byKey(const ValueKey('player-hover-preview-trigger')),
          ),
        );
        await tester.pump();
        await tester.pump(playerHoverIntentDelay);
        await tester.pumpAndSettle();
      }

      await open();
      expect(reads, ['tour']);
      expect(find.text('Missing opponent'), findsOneWidget);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      reads.clear();
      await tester.pumpWidget(host(fail: true));
      expect(reads, isEmpty);
      await open();
      expect(reads, ['tour']);
      expect(find.text('Real opponent'), findsOneWidget);
      expect(find.byType(OfficialPlayerResultRow), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
  test(
    'merge requires identity, exact round and tour ownership; games and ambiguity win',
    () {
      List<OfficialRoundResult> merge(
        List<OfficialRoundResults> rounds, {
        List<TournamentGameSummary> games = const [game],
      }) => playerHoverMissingOfficialResults(
        player,
        games,
        rounds,
        tourIds: const ['tour'],
      );
      expect(merge([round(outcome())]).single.roundId, 'r2');
      expect(merge([round(outcome(id: 'r1'))]), isEmpty);
      expect(merge([round(outcome(fide: '999'))]), isEmpty);
      expect(merge([round(outcome(tour: 'foreign'))]), isEmpty);
      expect(merge([round(outcome()), round(outcome())]), isEmpty);
      expect(
        merge([
          OfficialRoundResults(
            roundId: 'wrong',
            roundName: '',
            roundNumber: 2,
            tourId: 'tour',
            results: [outcome()],
          ),
        ]),
        isEmpty,
      );
    },
  );
  testWidgets(
    'compact merges genuine games and official outcomes without count badge or board action',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: PlayerHoverPreview(
                  player: player,
                  games: const [game],
                  officialResults: [round(outcome())],
                  onOpenOpponentInNewTab: (_) {},
                  onOpenGameInNewTab: (_) => opened++,
                ),
              ),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('player-hover-preview-trigger')),
        ),
      );
      await tester.pump();
      await tester.pump(playerHoverIntentDelay);
      await tester.pumpAndSettle();
      expect(find.byType(OfficialPlayerResultRow), findsOneWidget);
      expect(find.text('Missing opponent'), findsOneWidget);
      expect(find.text('Real opponent'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('player-hover-preview-card')))
            .width,
        420,
      );
      await tester.tap(find.text('1').first);
      await tester.pump();
      expect(opened, 0);
      await tester.tap(find.byKey(const ValueKey('game-result-real')));
      expect(opened, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
