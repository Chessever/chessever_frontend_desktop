import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_rewards.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/play_profile/play_badge_cabinet.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/theme/app_theme.dart';

/// The arrow's own [ScrollEdgeArrows] host and the scroll position under it.
ScrollPosition _positionUnder(WidgetTester tester, Finder arrow) {
  final host = find.ancestor(
    of: arrow,
    matching: find.byType(ScrollEdgeArrows),
  );
  final scrollable = find.descendant(
    of: host.first,
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily);
    for (final weight in ['Regular', 'SemiBold', 'Bold', 'Black']) {
      font.addFont(
        rootBundle.load('packages/forui/assets/fonts/inter/Inter-$weight.ttf'),
      );
    }
    await font.load();
  });

  testWidgets('profile Stats page scrolls by arrow with no scrollbar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopAccountIdentityProvider.overrideWith(() => _Identity()),
          playUserProfileProvider.overrideWith((ref) async => _profile),
          playRecentGamesProvider.overrideWith((ref) async => []),
          playAchievementsProvider.overrideWith((ref) => _Achievements()),
          playRatingHistoryProvider.overrideWith(
            (ref, tc) async => <PlayRatingPoint>[],
          ),
          myPrepPlayerIdProvider.overrideWith((ref) => _MyPrep()),
          playerWorkspaceProvider.overrideWith((ref) => _Workspace()),
        ],
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: FTheme(
              data: FThemes.zinc.dark,
              child: const PlayProfilePane(),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(find.byType(Scrollbar), findsNothing);
    expect(find.byType(RawScrollbar), findsNothing);
    final down = find.byIcon(Icons.keyboard_arrow_down_rounded);
    expect(down, findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);

    final position = _positionUnder(tester, down);
    expect(position.pixels, 0);
    await tester.tap(down);
    await _settle(tester);
    expect(position.pixels, greaterThan(0));
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('badge cabinet page and Recently earned strip take arrows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final at = DateTime.now().subtract(const Duration(days: 5));
    final state = PlayAchievementsState(
      stats: const PlayAchievementStats(gamesPlayed: 40, wins: 20),
      unlocked: const {},
      recentUnlocks: [
        for (final track in kPlayBadgeTracks.take(8))
          PlayBadgeTierUp(trackKey: track.key, tier: 1, at: at),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: FTheme(
            data: FThemes.zinc.dark,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: PlayBadgeCabinet(
                state: state,
                onClaim: (_) async {},
                onClaimAll: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(find.byType(Scrollbar), findsNothing);
    expect(find.byType(RawScrollbar), findsNothing);
    expect(find.text('Recently earned'), findsOneWidget);

    // The page itself runs past the view.
    final down = find.byIcon(Icons.keyboard_arrow_down_rounded);
    expect(down, findsOneWidget);
    final page = _positionUnder(tester, down);
    await tester.tap(down);
    await _settle(tester);
    expect(page.pixels, greaterThan(0));
    page.jumpTo(0);
    await _settle(tester);

    // Eight badges at 114 px each do not fit across 608 px.
    final right = find.byIcon(Icons.chevron_right_rounded);
    expect(right, findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    final strip = _positionUnder(tester, right);
    expect(strip.axis, Axis.horizontal);
    await tester.tap(right);
    await _settle(tester);
    expect(strip.pixels, greaterThan(0));
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final _profile = PlayUserProfile(
  displayName: 'Berkay Can',
  avatarSeed: 'berkay',
  achievementPoints: 30,
  createdAt: DateTime(2026, 5, 13),
  lastGameAt: DateTime(2026, 11, 2),
  ratings: const {
    RatedTimeControl.classical: PlayRatingStats.initial,
    RatedTimeControl.rapid: PlayRatingStats(
      rating: 1190,
      peak: 1200,
      gamesPlayed: 3,
      wins: 0,
      losses: 3,
      draws: 0,
    ),
    RatedTimeControl.blitz: PlayRatingStats(
      rating: 1187,
      peak: 1200,
      gamesPlayed: 3,
      wins: 0,
      losses: 3,
      draws: 0,
    ),
    RatedTimeControl.bullet: PlayRatingStats(
      rating: 1157,
      peak: 1200,
      gamesPlayed: 8,
      wins: 1,
      losses: 7,
      draws: 0,
    ),
  },
);

class _Identity extends DesktopAccountIdentityNotifier {
  @override
  DesktopAccountIdentity build() =>
      const DesktopAccountIdentity(userId: 'signed-in');
}

class _MyPrep extends StateNotifier<AsyncValue<String?>>
    implements MyPrepPlayerIdNotifier {
  _MyPrep() : super(const AsyncValue.data(null));

  final linked = <String>[];

  @override
  Future<void> link(String playerId) async {
    linked.add(playerId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Workspace extends StateNotifier<PlayerWorkspaceState>
    implements PlayerWorkspaceNotifier {
  _Workspace()
    : super(
        PlayerWorkspaceState(
          players: [
            PlayerWorkspacePlayer(
              id: 'p1',
              displayName: 'Berkay Can',
              createdAtMs: 0,
              accounts: const {
                PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.lichess,
                  username: 'devberkay',
                  gameCount: 412,
                ),
                PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.chesscom,
                  username: 'berkaycan',
                  gameCount: 1200,
                ),
              },
            ),
            const PlayerWorkspacePlayer(
              id: 'p2',
              displayName: 'Magnus Carlsen',
              createdAtMs: 0,
              accounts: {
                PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
                  source: PlayerWorkspaceSource.chessever,
                  username: 'Carlsen, Magnus',
                  gameCount: 4210,
                ),
              },
            ),
          ],
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Achievements extends StateNotifier<PlayAchievementsState>
    implements PlayAchievementsNotifier {
  _Achievements()
    : super(
        const PlayAchievementsState(
          stats: PlayAchievementStats(),
          unlocked: {
            PlayAchievementId.firstGame,
            PlayAchievementId.firstWin,
            PlayAchievementId.tenGames,
          },
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
