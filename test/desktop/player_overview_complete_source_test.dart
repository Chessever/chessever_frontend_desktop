import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/state/player_stats_provider.dart';
import 'package:chessever/desktop/widgets/player_stats_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets(
    'Overview defaults to all six and makes explicit filters visible',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <PlayerStatsRequest>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerStatsProvider.overrideWith((ref, request) async {
              requests.add(request);
              return _snapshot(request.timeControlCategory == null);
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: PlayerStatsDashboard(
                sources: [
                  PlayerStatsSource(
                    label: 'ChessEver',
                    accent: Colors.cyan,
                    path: '/six-source.pgn',
                    gameCount: 6,
                    kind: PlayerWorkspaceSource.chessever,
                  ),
                ],
                aliases: ['Elise Moreau'],
                playerFideId: '99999901',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests.last.timeControlCategory, isNull);
      expect(requests.last.preferredRatingTimeControl, 'classical');
      expect(find.text('6 of 6 games'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('player-overview-tempo-classical')),
      );
      await tester.pumpAndSettle();
      expect(requests.last.timeControlCategory, 'classical');
      expect(find.text('2 of 6 games'), findsOneWidget);
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(requests.last.timeControlCategory, isNull);
      expect(find.text('6 of 6 games'), findsOneWidget);
    },
  );
}

PlayerStatsSnapshot _snapshot(bool all) => PlayerStatsSnapshot(
  overall:
      all
          ? const PlayerResultTally(wins: 1, draws: 3, losses: 2)
          : const PlayerResultTally(losses: 2),
  asWhite:
      all
          ? const PlayerResultTally(draws: 3, losses: 2)
          : const PlayerResultTally(losses: 2),
  asBlack: all ? const PlayerResultTally(wins: 1) : PlayerResultTally.empty,
  ratingSeries: const [],
  openings: const [],
  opponents: const [],
  years: const [],
  lengthBuckets: const [],
  timeControls: const [
    PlayerTimeControlStat(category: 'classical', count: 2),
    PlayerTimeControlStat(category: 'rapid', count: 4),
  ],
);
