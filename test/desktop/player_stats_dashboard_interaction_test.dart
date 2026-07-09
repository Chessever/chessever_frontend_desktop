import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/state/player_stats_provider.dart';
import 'package:chessever/desktop/widgets/player_stats_dashboard.dart';
import 'package:chessever/desktop/widgets/tempo_icon.dart';
import 'package:chessever/utils/png_asset.dart';

void main() {
  const snapshot = PlayerStatsSnapshot(
    overall: PlayerResultTally(wins: 5, draws: 2, losses: 3),
    asWhite: PlayerResultTally(wins: 3, draws: 1, losses: 1),
    asBlack: PlayerResultTally(wins: 2, draws: 1, losses: 2),
    ratingSeries: <PlayerRatingSpot>[],
    openings: <PlayerOpeningStat>[],
    opponents: <PlayerOpponentStat>[],
    years: <PlayerYearStat>[
      PlayerYearStat(
        year: 2023,
        tally: PlayerResultTally(wins: 2, draws: 1, losses: 1),
        timeControls: <PlayerTimeControlStat>[
          PlayerTimeControlStat(category: 'classical', count: 3),
          PlayerTimeControlStat(category: 'rapid', count: 1),
        ],
        sources: <PlayerSourceStat>[
          PlayerSourceStat(label: 'ChessEver', count: 3),
          PlayerSourceStat(label: 'Lichess', count: 1),
        ],
      ),
      PlayerYearStat(
        year: 2024,
        tally: PlayerResultTally(wins: 3, draws: 1, losses: 2),
        timeControls: <PlayerTimeControlStat>[
          PlayerTimeControlStat(category: 'blitz', count: 3),
          PlayerTimeControlStat(category: 'bullet', count: 2),
          PlayerTimeControlStat(category: 'ultrabullet', count: 1),
        ],
        sources: <PlayerSourceStat>[
          PlayerSourceStat(label: 'Chess.com', count: 3),
          PlayerSourceStat(label: 'Lichess', count: 3),
        ],
      ),
    ],
    lengthBuckets: <PlayerLengthBucket>[
      PlayerLengthBucket(label: '0–20', count: 3),
      PlayerLengthBucket(label: '21–40', count: 7),
    ],
    timeControls: <PlayerTimeControlStat>[
      PlayerTimeControlStat(category: 'classical', count: 3),
      PlayerTimeControlStat(category: 'rapid', count: 1),
      PlayerTimeControlStat(category: 'blitz', count: 3),
      PlayerTimeControlStat(category: 'bullet', count: 2),
      PlayerTimeControlStat(category: 'ultrabullet', count: 1),
    ],
  );

  Future<void> pumpDashboard(
    WidgetTester tester, {
    ValueChanged<PlayerOverviewFilterRequest>? onOverviewFilter,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 680));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerStatsProvider.overrideWith((ref, request) async => snapshot),
        ],
        child: MaterialApp(
          home: SizedBox(
            width: 1000,
            height: 680,
            child: PlayerStatsDashboard(
              sources: const <PlayerStatsSource>[
                PlayerStatsSource(
                  label: 'Combined',
                  accent: Color(0xFF4EA1FF),
                  path: '/tmp/combined.pgn',
                  gameCount: 10,
                  kind: PlayerWorkspaceSource.combined,
                ),
              ],
              aliases: const <String>['Test Player'],
              onOverviewFilter: onOverviewFilter,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Players tempo pills preserve the original asset artwork', (
    tester,
  ) async {
    await pumpDashboard(tester);

    const expected = <String, String>{
      'classical': PngAsset.classicalIcon,
      'rapid': PngAsset.rapidIcon,
      'blitz': PngAsset.blitzIcon,
      'bullet': PngAsset.bulletIcon,
      'ultrabullet': PngAsset.ultraBulletIcon,
    };
    for (final entry in expected.entries) {
      final iconFinder = find.byKey(
        ValueKey<String>('player-overview-tempo-${entry.key}'),
      );
      expect(iconFinder, findsOneWidget, reason: entry.key);
      expect(tester.widget<TempoIcon>(iconFinder).color, isNull);
      final image = tester.widget<Image>(
        find.descendant(of: iconFinder, matching: find.byType(Image)),
      );
      expect((image.image as AssetImage).assetName, entry.value);
    }
  });

  testWidgets('year hover is an overlay and never changes scroll geometry', (
    tester,
  ) async {
    await pumpDashboard(tester);
    final chart = find.byKey(
      const ValueKey<String>('player-games-by-year-chart'),
    );
    final verticalScrollable =
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first;
    await tester.scrollUntilVisible(chart, 260, scrollable: verticalScrollable);
    await tester.pumpAndSettle();

    final position = tester.state<ScrollableState>(verticalScrollable).position;
    final sizeBefore = tester.getSize(chart);
    final extentBefore = position.maxScrollExtent;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(tester.getCenter(chart));
    await tester.pump();

    final overlay = find.byKey(
      const ValueKey<String>('player-games-by-year-hover-overlay'),
    );
    expect(overlay, findsOneWidget);
    final ignorePointerAncestors = find.ancestor(
      of: overlay,
      matching: find.byType(IgnorePointer),
    );
    expect(ignorePointerAncestors, findsWidgets);
    expect(
      tester
          .widgetList<IgnorePointer>(ignorePointerAncestors)
          .any((widget) => widget.ignoring),
      isTrue,
    );
    expect(tester.getSize(chart), sizeBefore);
    expect(position.maxScrollExtent, extentBefore);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    expect(overlay, findsNothing);
    expect(tester.getSize(chart), sizeBefore);
    expect(position.maxScrollExtent, extentBefore);
    await mouse.removePointer();
  });

  testWidgets('vertical wheel scrolls the dashboard while over the chart', (
    tester,
  ) async {
    await pumpDashboard(tester);
    final chart = find.byKey(
      const ValueKey<String>('player-games-by-year-chart'),
    );
    final verticalScrollable =
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first;
    await tester.scrollUntilVisible(chart, 260, scrollable: verticalScrollable);
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(verticalScrollable).position;
    final before = position.pixels;
    final delta = before < position.maxScrollExtent - 40 ? 80.0 : -80.0;

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(chart),
        scrollDelta: Offset(0, delta),
      ),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, isNot(before));
  });

  testWidgets('clicking a year still emits the exact Games filter', (
    tester,
  ) async {
    PlayerOverviewFilterRequest? emitted;
    await pumpDashboard(tester, onOverviewFilter: (value) => emitted = value);
    final chart = find.byKey(
      const ValueKey<String>('player-games-by-year-chart'),
    );
    final verticalScrollable =
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first;
    await tester.scrollUntilVisible(chart, 260, scrollable: verticalScrollable);
    await tester.pumpAndSettle();
    final rect = tester.getRect(chart);
    await tester.tapAt(Offset(rect.left + rect.width * 0.25, rect.center.dy));
    await tester.pump();

    expect(emitted?.facet, PlayerOverviewFilterFacet.year);
    expect(emitted?.year, 2023);
    expect(emitted?.sourcePath, '/tmp/combined.pgn');
  });
}
