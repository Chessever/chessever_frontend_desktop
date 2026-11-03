import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/theme/app_theme.dart';

void main() {
  Future<_MyPrep> pumpProfile(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final myPrep = _MyPrep();
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
          myPrepPlayerIdProvider.overrideWith((ref) => myPrep),
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
    await tester.pump();
    await tester.pump();
    return myPrep;
  }

  testWidgets('Prep is the primary tab and asks for the user\'s own profile', (
    tester,
  ) async {
    await pumpProfile(tester);

    expect(find.text('Prepare against yourself'), findsOneWidget);
    expect(find.text('Create my prep profile'), findsOneWidget);
    expect(find.text('Record'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing an existing prep profile links it as the user\'s', (
    tester,
  ) async {
    final myPrep = await pumpProfile(tester);

    await tester.tap(find.text('This is me').first);
    await tester.pump();

    expect(myPrep.linked, ['p1']);
  });

  testWidgets('Play stats keeps the ratings, record and badges', (
    tester,
  ) async {
    await pumpProfile(tester);

    await tester.tap(find.text('Play stats'));
    await tester.pump();

    expect(find.text('Record'), findsOneWidget);
    expect(find.text('1157'), findsOneWidget);
    expect(find.text('Bullet rating'), findsOneWidget);

    await tester.tap(find.text('Rapid'));
    await tester.pump();
    expect(find.text('Rapid rating'), findsOneWidget);
    // Let the chart's entry animation finish before teardown.
    await tester.pump(const Duration(seconds: 3));
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
