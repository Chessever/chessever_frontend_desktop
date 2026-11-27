import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_stats_summary.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/play_profile/play_profile_charts.dart';
import 'package:chessever/theme/app_theme.dart';

PlayGameRecord _game(
  int i, {
  required String result,
  required String color,
  String? opening,
  String? eco,
  int opp = 1400,
  String tc = 'blitz',
  DateTime? at,
}) {
  return PlayGameRecord(
    localGameKey: 'g$i',
    source: PlayGameSource.singlePlay,
    playedAt: at ?? DateTime(2026, 11, 1).add(Duration(hours: i)),
    result: result,
    endReason: 'checkmate',
    startingFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    finalFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    movesUci: List.filled(40, 'e2e4'),
    pgn: '',
    pgnHeaders: const {},
    metadata: const {},
    analysis: const {},
    badgeContributions: const [],
    eco: eco,
    openingName: opening,
    timeCategory: tc,
    humanColor: color,
    opponentElo: opp,
    whiteName: color == 'white' ? 'You' : 'Bot $i',
    blackName: color == 'white' ? 'Bot $i' : 'You',
  );
}

final _games = <PlayGameRecord>[
  _game(
    0,
    result: '1-0',
    color: 'white',
    opening: 'Italian Game: Giuoco Piano',
    eco: 'C50',
    opp: 1300,
  ),
  _game(
    1,
    result: '1-0',
    color: 'white',
    opening: 'Italian Game: Two Knights',
    eco: 'C55',
    opp: 1500,
  ),
  _game(
    2,
    result: '1/2-1/2',
    color: 'white',
    opening: 'Queen\'s Gambit Declined',
    eco: 'D30',
    opp: 1610,
  ),
  _game(
    3,
    result: '0-1',
    color: 'black',
    opening: 'Sicilian Defense: Najdorf',
    eco: 'B90',
    opp: 1450,
  ),
  _game(
    4,
    result: '1-0',
    color: 'black',
    opening: 'Sicilian Defense: Najdorf',
    eco: 'B90',
    opp: 1700,
  ),
  _game(
    5,
    result: '0-1',
    color: 'white',
    opening: null,
    eco: 'A00',
    opp: 1250,
    tc: 'rapid',
  ),
  _game(
    6,
    result: '1-0',
    color: 'white',
    opening: 'Italian Game',
    eco: 'C50',
    opp: 1420,
  ),
  _game(
    7,
    result: '1-0',
    color: 'white',
    opening: 'Italian Game',
    eco: 'C50',
    opp: 1430,
  ),
];

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

  test('summary groups openings by family and colour', () {
    final s = PlayStatsSummary.from(_games, now: DateTime(2026, 11, 2));
    expect(s.overall.games, 8);
    expect(s.overall.wins, 5);
    expect(s.overall.draws, 1);
    expect(s.overall.losses, 2);
    expect(s.asWhite.games, 6);
    expect(s.whiteOpenings.first.name, 'Italian Game');
    expect(s.whiteOpenings.first.record.games, 4);
    expect(s.whiteOpenings.first.record.scorePct, 100);
    expect(s.blackOpenings.single.name, 'Sicilian Defense');
    expect(s.blackOpenings.single.record.scorePct, 50);
    expect(s.whiteOpenings.map((o) => o.name), contains('A00'));
  });

  test('summary tracks streaks, form, strength bands and clocks', () {
    final s = PlayStatsSummary.from(_games, now: DateTime(2026, 11, 2));
    expect(s.bestWinStreak, 2);
    expect(s.current!.kind, PlayStreakKind.win);
    expect(s.current!.length, 2);
    expect(s.form.length, 8);
    expect(s.form.last, PlayStreakKind.win);
    expect(s.bands.map((b) => b.from), [1200, 1400, 1600]);
    expect(s.strongestWin!.opponentElo, 1500);
    expect(s.byTimeControl[RatedTimeControl.rapid]!.games, 1);
    expect(s.performance, isNotNull);
    expect(s.activity.values.fold<int>(0, (a, b) => a + b), 8);
    expect(openingFamily(null, null), isNull);
    expect(openingFamily('  ', 'B01'), 'B01');
  });

  testWidgets('a played history fills every Stats panel without errors', (
    tester,
  ) async {

    final history = [
      for (var i = 0; i < 14; i++)
        PlayRatingPoint(
          playedAt: DateTime(2026, 10, 1).add(Duration(days: i)),
          rating: 1200 + i * 12 - (i.isOdd ? 30 : 0),
          delta: i.isOdd ? -18 : 22,
          opponentElo: 1400,
          score: i.isOdd ? 0 : 1,
          kFactor: 40,
          gameKey: 'h$i',
          rd: 300 - i * 15.0,
        ),
    ];
    for (final size in const [Size(1600, 1100), Size(820, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopAccountIdentityProvider.overrideWith(() => _Identity()),
            playUserProfileProvider.overrideWith(
              (ref) async => PlayUserProfile.fallback('Tester').copyWithRating(
                RatedTimeControl.blitz,
                const PlayRatingStats(
                  rating: 1342,
                  peak: 1380,
                  gamesPlayed: 14,
                  wins: 8,
                  losses: 6,
                  draws: 0,
                  rd: 88,
                ),
              ),
            ),
            playRecentGamesProvider.overrideWith((ref) async => _games),
            playAchievementsProvider.overrideWith((ref) => _Achievements()),
            playRatingHistoryProvider.overrideWith(
              (ref, tc) async =>
                  tc == RatedTimeControl.blitz ? history : <PlayRatingPoint>[],
            ),
            myPrepPlayerIdProvider.overrideWith((ref) => _MyPrep()),
            playerWorkspaceProvider.overrideWith((ref) => _Workspace()),
          ],
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: FTheme(
                data: FThemes.zinc.dark,
                child: PlayProfilePane(key: ValueKey(size)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Openings as White'), findsOneWidget);
      expect(find.text('Italian Game'), findsOneWidget);
      expect(find.text('Sicilian Defense'), findsOneWidget);
      expect(find.text('1342'), findsWidgets);
      expect(tester.takeException(), isNull);

      // Hover the rating chart: the readout follows the pointer.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(PlayRatingTimeline)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await gesture.removePointer();

      await tester.tap(find.text('Achievements'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Closest next'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    // The game cards read engine settings behind a 4 s database timeout.
    await tester.pump(const Duration(seconds: 5));
    tester.view.reset();
  });
}

class _Identity extends DesktopAccountIdentityNotifier {
  @override
  DesktopAccountIdentity build() =>
      const DesktopAccountIdentity(userId: 'signed-in');
}

class _MyPrep extends StateNotifier<AsyncValue<String?>>
    implements MyPrepPlayerIdNotifier {
  _MyPrep() : super(const AsyncValue.data(null));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Workspace extends StateNotifier<PlayerWorkspaceState>
    implements PlayerWorkspaceNotifier {
  _Workspace() : super(const PlayerWorkspaceState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Achievements extends StateNotifier<PlayAchievementsState>
    implements PlayAchievementsNotifier {
  _Achievements()
    : super(
        const PlayAchievementsState(
          stats: PlayAchievementStats(gamesPlayed: 8, wins: 5, xp: 520),
          unlocked: {PlayAchievementId.firstGame, PlayAchievementId.firstWin},
          claimable: {PlayAchievementId.fiveWins},
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
