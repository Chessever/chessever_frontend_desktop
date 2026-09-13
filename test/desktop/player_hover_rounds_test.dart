import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/state/player_hover_rounds.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/player_hover_preview.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';

PlayerHoverRound round(String id, String name, [String? start]) =>
    PlayerHoverRound(
      id: id,
      name: name,
      startsAt: start == null ? null : DateTime.parse(start),
    );

TournamentGameSummary game(
  String id,
  String roundId,
  String name, {
  String white = 'Carlsen, Magnus',
  String label = '',
}) => TournamentGameSummary(
  id: id,
  name: id,
  whitePlayer: white,
  blackPlayer: 'Nepomniachtchi, Ian',
  hasPgn: true,
  roundId: roundId,
  roundName: name,
  roundLabel: label,
);

void main() {
  test('schedule identity is event-wide and stable across player requests', () {
    expect(
      playerHoverRoundsKey(['b', 'a', 'a']),
      playerHoverRoundsKey(['a', 'b']),
    );
    expect(playerHoverRoundsKey(['a']), isNot(playerHoverRoundsKey(['b'])));
  });
  test('explicit rounds only; years/team digits are not official numbers', () {
    expect(explicitPlayerHoverRoundNumber('Round 11'), 11);
    expect(explicitPlayerHoverRoundNumber('r 02'), 2);
    expect(explicitPlayerHoverRoundNumber('0'), isNull);
    expect(explicitPlayerHoverRoundNumber('Championship 2026'), isNull);
    expect(explicitPlayerHoverRoundNumber('Team 2 semifinal'), isNull);
    expect(
      playerHoverRoundLabels([
        round('named', 'Semifinal'),
        round('r1', 'Round 1'),
      ]),
      {'named': 'R2', 'r1': 'R1'},
    );
  });

  test(
    'complete schedule maps championship after semifinals for every player',
    () {
      final rounds = [
        round('final2', 'Championship game 2', '2026-09-12T18:00:00Z'),
        round('semi', 'Semifinal', '2026-09-10T18:00:00Z'),
        round('final1', 'Championship game 1', '2026-09-12T17:00:00Z'),
      ];
      final labels = playerHoverRoundLabels(rounds);
      expect(labels, {'semi': 'R1', 'final1': 'R2', 'final2': 'R3'});
      final games = [
        game('a', 'final2', 'Championship game 2'),
        game('b', 'final1', 'Championship game 1'),
      ];
      for (final player in ['Carlsen, Magnus', 'Nepomniachtchi, Ian']) {
        final selected = playerHoverPreviewGames(
          PlayerHoverPreviewIdentity(name: player),
          games,
        );
        expect(selected.map((g) => labels[g.roundId]), ['R3', 'R2']);
      }
      expect(games.first.roundName, 'Championship game 2');
    },
  );

  test(
    'only exact scheduled names share ordinals, never fuzzy/missing dates',
    () {
      final labels = playerHoverRoundLabels([
        round('a', 'Championship', '2026-09-12T18:00:00Z'),
        round('b', 'Championship', '2026-09-12T18:00:00Z'),
        round('case', 'championship', '2026-09-12T18:00:00Z'),
        round('space', 'Championship ', '2026-09-12T18:00:00Z'),
        round('missing1', 'Semifinal'),
        round('missing2', 'Semifinal'),
      ]);
      expect(labels, {
        'a': 'R1',
        'b': 'R1',
        'case': 'R2',
        'space': 'R3',
        'missing1': 'R4',
        'missing2': 'R5',
      });
    },
  );

  test(
    'pagination continues past short server pages; no partial publication',
    () async {
      final offsets = <int>[];
      final result = await loadPlayerHoverRounds((offset, size) async {
        offsets.add(offset);
        return offset < 3
            ? [
              {'id': '$offset', 'name': 'Match $offset'},
            ]
            : [];
      });
      expect(offsets, [0, 1, 2, 3]);
      expect(playerHoverRoundLabels(result)['2'], 'R3');
      await expectLater(
        loadPlayerHoverRounds((offset, size) async {
          if (offset > 0) throw StateError('page failed');
          return [
            {'id': 'first', 'name': 'Semifinal'},
          ];
        }),
        throwsStateError,
      );
    },
  );

  testWidgets('compact single-line named labels expose full keyboard tooltip', (
    tester,
  ) async {
    final rows = [
      game('first', 'semi', 'Semifinal'),
      game('second', 'final', 'Championship'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerHoverPreview(
                player: const PlayerHoverPreviewIdentity(
                  name: 'Carlsen, Magnus',
                ),
                games: rows,
                rounds: [
                  round('semi', 'Semifinal'),
                  round('final', 'Championship'),
                ],
                onOpenOpponentInNewTab: (_) {},
                onOpenGameInNewTab: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final trigger = find.byKey(const ValueKey('player-hover-preview-trigger'));
    final pointer = TestPointer(40, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(trigger)));
    await tester.pump(
      playerHoverIntentDelay + const Duration(milliseconds: 120),
    );
    await tester.pumpAndSettle();
    final label = tester.widget<Text>(
      find.byKey(const ValueKey('game-round-second')),
    );
    expect(label.data, 'R2');
    expect(label.maxLines, 1);
    expect(label.softWrap, false);
    final tooltip = find.byKey(const ValueKey('game-round-tooltip-second'));
    final message = tester.widget<DesktopTooltip>(tooltip).message;
    expect(message, contains('Championship'));
    expect(message, contains('not an official round number'));
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(tooltip)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(message), findsOneWidget);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(trigger)));
    await tester.pumpAndSettle();
    expect(find.text(message), findsNothing);
    final focus =
        find.descendant(of: tooltip, matching: find.byType(Focus)).first;
    Focus.of(
      tester.element(find.byWidget(tester.widget<Focus>(focus).child)),
    ).requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(message), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text(message), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'numeric source label is preserved; missing named map stays unknown',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: PlayerHoverPreview(
                  player: const PlayerHoverPreviewIdentity(
                    name: 'Carlsen, Magnus',
                  ),
                  games: [
                    game('numeric', 'r7', 'Round 7', label: '7'),
                    game('subround', 'r7-1', '7.1', label: '7.1'),
                    game('unknown', 'uuid-2026', 'Championship'),
                  ],
                  onOpenOpponentInNewTab: (_) {},
                  onOpenGameInNewTab: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      final pointer = TestPointer(41, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(
          tester.getCenter(
            find.byKey(const ValueKey('player-hover-preview-trigger')),
          ),
        ),
      );
      await tester.pump(
        playerHoverIntentDelay + const Duration(milliseconds: 120),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('game-round-numeric')))
            .data,
        '7',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('game-round-subround')))
            .data,
        '7.1',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('game-round-unknown')))
            .data,
        'R?',
      );
    },
  );
}
