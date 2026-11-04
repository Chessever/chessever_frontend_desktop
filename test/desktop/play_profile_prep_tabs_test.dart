import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';

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

  Future<_MyPrep> pumpProfile(
    WidgetTester tester, {
    bool premium = false,
  }) async {
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
          if (premium) ...[
            subscriptionProvider.overrideWith(
              (ref) => SubscriptionNotifier.stub(
                SubscriptionState(
                  isSubscribed: true,
                  expirationDate: DateTime.now().add(const Duration(days: 30)),
                ),
              ),
            ),
            desktopEntitlementProvider.overrideWith(
              (ref) => const DesktopEntitlementSnapshot(
                accountId: 'acct-a',
                generation: 1,
              ),
            ),
          ],
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

    expect(find.text('Attach your own usernames'), findsOneWidget);
    expect(find.text('Attach your username'), findsOneWidget);
    expect(find.text('Record'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attaching a username starts with where the user plays', (
    tester,
  ) async {
    await pumpProfile(tester, premium: true);

    await tester.tap(find.text('Attach your username'));
    await tester.pumpAndSettle();

    expect(
      find.text('Where do you play? You can attach more accounts later.'),
      findsOneWidget,
    );
    expect(find.text('Lichess username'), findsOneWidget);
    expect(find.text('Chess.com username'), findsOneWidget);
    expect(find.text('ChessEver player'), findsOneWidget);
    expect(find.text('PGN file'), findsNothing);
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

  testWidgets(
    'Play stats keeps the record and badges without personal ratings',
    (tester) async {
      await pumpProfile(tester);

      await tester.tap(find.text('Play stats'));
      await tester.pump();

      expect(find.text('Record'), findsOneWidget);
      expect(find.text('1157'), findsNothing);
      expect(find.textContaining('rating'), findsNothing);
      expect(find.text('ChessEver player'), findsNothing);
      expect(find.text('Joined May 13, 2026'), findsOneWidget);

      await tester.tap(find.text('Achievements'));
      await tester.pump();
      expect(find.text('Record'), findsNothing);

      await tester.tap(find.text('Games'));
      await tester.pump();
      expect(find.text('Highest'), findsNothing);
      expect(find.text('Lowest'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );
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
