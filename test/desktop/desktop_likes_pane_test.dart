import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/desktop_likes_pane.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/services/likes/community_likes_repository.dart';
import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_like_count_heart.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';

import 'support/collections_fakes.dart';

const _kFen =
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

class _FakeRepository implements CommunityLikesRepository {
  _FakeRepository(
    this.result, {
    this.laterPages = const [],
    this.byPeriod = const {},
    this.pendingByPeriod = const {},
    this.byQuery = const {},
  });

  final CommunityLikesResult result;
  final Map<CommunityLikesPeriod, CommunityLikesResult> byPeriod;
  final Map<CommunityLikesPeriod, Future<CommunityLikesResult>> pendingByPeriod;
  final Map<CommunityLikesQuery, CommunityLikesResult> byQuery;
  final List<CommunityLikesResult> laterPages;
  final List<CommunityLikesQuery> queries = [];
  final List<CommunityLikesCursor> cursors = [];

  @override
  Future<CommunityLikesResult> fetch(
    CommunityLikesQuery query, {
    int limit = kCommunityLikesPageSize,
    CommunityLikesCursor? after,
  }) async {
    queries.add(query);
    if (after != null) {
      cursors.add(after);
      return laterPages[cursors.length - 1];
    }
    final pending = pendingByPeriod[query.period];
    if (pending != null) return await pending;
    return byQuery[query] ?? byPeriod[query.period] ?? result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGameStream extends GameStreamRepository {
  @override
  Stream<Map<String, dynamic>?> subscribeToGameUpdates(String gameId) =>
      const Stream.empty();

  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) =>
      const Stream.empty();

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) => const Stream.empty();
}

class _NoEvalBoardSettings extends BoardSettingsNotifierNew {
  _NoEvalBoardSettings(this.initialMode);

  final GamesListViewMode initialMode;
  final List<int> savedViewModes = [];

  @override
  Future<BoardSettingsNew> build() async {
    final settings = BoardSettingsNew(
      showEvaluationBar: false,
      gamesListViewModeIndex: initialMode.index,
    );
    state = AsyncValue.data(settings);
    return settings;
  }

  @override
  Future<void> setGamesListViewModeIndex(int index) async {
    savedViewModes.add(index);
    state = AsyncValue.data(
      state.requireValue.copyWith(gamesListViewModeIndex: index),
    );
  }
}

class _NoGaugeEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings(showEngineGauge: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

PlayerCard _player(String name, int fideId) => PlayerCard(
  name: name,
  federation: 'NOR',
  title: 'GM',
  rating: 2800,
  countryCode: 'NOR',
  fideId: fideId,
  team: null,
);

CommunityLikesEntry _entry(int rank, int likes, PlayerCard w, PlayerCard b) =>
    CommunityLikesEntry(
      rank: rank,
      likes: likes,
      game: GamesTourModel(
        gameId: 'game-$rank',
        source: GameSource.gamebase,
        whitePlayer: w,
        blackPlayer: b,
        whiteTimeDisplay: '--:--',
        blackTimeDisplay: '--:--',
        whiteClockCentiseconds: 0,
        blackClockCentiseconds: 0,
        gameStatus: GameStatus.whiteWins,
        roundId: 'gamebase',
        tourId: 'Norway Chess',
        eventName: 'Norway Chess',
        fen: _kFen,
      ),
    );

Future<_FakeRepository> _pump(
  WidgetTester tester, {
  CommunityLikesResult? result,
  List<CommunityLikesResult> laterPages = const [],
  Map<CommunityLikesPeriod, CommunityLikesResult> byPeriod = const {},
  Map<CommunityLikesPeriod, Future<CommunityLikesResult>> pendingByPeriod =
      const {},
  Map<CommunityLikesQuery, CommunityLikesResult> byQuery = const {},
  SubscriptionState? subscription,
  GamesListViewMode viewMode = GamesListViewMode.gamesCard,
  double width = 1440,
  bool readOnlyPresentation = false,
}) async {
  // Wide enough that the test font's full-em glyphs fit the compact
  // scorecards' rating rows, the column width every games list uses.
  tester.view.physicalSize = Size(width, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final carlsen = _player('Carlsen, Magnus', 1503014);
  final caruana = _player('Caruana, Fabiano', 2020009);
  final gukesh = _player('Gukesh D', 46616543);
  final repository = _FakeRepository(
    result ??
        CommunityLikesResult.ranked([
          _entry(1, 1240, carlsen, caruana),
          _entry(2, 31, gukesh, carlsen),
          _entry(3, 4, caruana, gukesh),
        ]),
    laterPages: laterPages,
    byPeriod: byPeriod,
    pendingByPeriod: pendingByPeriod,
    byQuery: byQuery,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        communityLikesRepositoryProvider.overrideWithValue(repository),
        subscriptionProvider.overrideWith(
          (ref) => FakeSubscription(subscription ?? SubscriptionState()),
        ),
        gameStreamRepositoryProvider.overrideWithValue(_FakeGameStream()),
        boardSettingsProviderNew.overrideWith(
          () => _NoEvalBoardSettings(viewMode),
        ),
        engineSettingsProviderNew.overrideWith(_NoGaugeEngineSettings.new),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return Scaffold(
              body: DesktopLikesPane(
                tabId: 'likes-1',
                readOnlyPresentation: readOnlyPresentation,
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return repository;
}

void main() {
  testWidgets(
    'read-only production Likes keeps ranking identities and counts without live card work',
    (tester) async {
      await _pump(
        tester,
        readOnlyPresentation: true,
        viewMode: GamesListViewMode.chessBoardGrid,
      );
      final cards =
          tester
              .widgetList<LiveDesktopGameCard>(find.byType(LiveDesktopGameCard))
              .toList();
      expect(cards.map((c) => c.game.gameId).toList(), [
        'game-1',
        'game-2',
        'game-3',
      ]);
      expect(
        cards.every((c) => c.readOnlyPresentation && !c.streamingEnabled),
        isTrue,
      );
      expect(
        tester
            .widgetList<DesktopBoardLikeBadge>(
              find.byType(DesktopBoardLikeBadge),
            )
            .map((b) => b.likes)
            .toList(),
        [1240, 31, 4],
      );
      expect(find.text('Public game preview'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  for (final mode in GamesListViewMode.values) {
    testWidgets(
      '${mode.name} keeps every slot filled after overlapping pages',
      (tester) async {
        final white = _player('White', 1);
        final black = _player('Black', 2);
        final entries = [
          for (var i = 1; i <= 6; i++) _entry(i, 10 - i, white, black),
        ];
        const firstCursor = (likes: 7, gameId: 'game-3', rank: 3);
        const overlapCursor = (likes: 6, gameId: 'game-3', rank: 6);
        const nextCursor = (likes: 5, gameId: 'game-5', rank: 10);
        final repository = await _pump(
          tester,
          viewMode: mode,
          result: CommunityLikesResult.ranked(
            entries.take(3).toList(),
            nextCursor: firstCursor,
          ),
          laterPages: [
            CommunityLikesResult.ranked(
              entries.take(3).toList(),
              nextCursor: overlapCursor,
            ),
            CommunityLikesResult.ranked([
              entries[1],
              entries[2],
              entries[3],
              entries[4],
            ], nextCursor: nextCursor),
            CommunityLikesResult.ranked([
              entries[0],
              entries[3],
              entries[5],
              entries[5],
            ]),
          ],
        );

        for (final count in [3, 5, 6]) {
          await tester.scrollUntilVisible(
            find.text('Show more'),
            300,
            scrollable: find.descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.tap(find.text('Show more'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          expect(tester.takeException(), isNull);
          final cards = tester.widgetList<LiveDesktopGameCard>(
            find.byType(LiveDesktopGameCard),
          );
          expect(cards.map((card) => card.game.gameId), [
            for (var i = 1; i <= count; i++) 'game-$i',
          ]);
          final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
          expect(grid.delegate.estimatedChildCount, count);
        }
        expect(repository.cursors, [firstCursor, overlapCursor, nextCursor]);
        expect(find.text('Show more'), findsNothing);

        await tester.tap(find.text('Players'));
        await tester.pump();
        // Each side played six distinct games with 9+8+7+6+5+4 likes.
        expect(find.text('39'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  testWidgets('top-right view controls update the shared saved choice', (
    tester,
  ) async {
    await _pump(tester);
    final toggle = find.byType(GameViewModeToggle);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopLikesPane)),
    );
    final settings =
        container.read(boardSettingsProviderNew.notifier)
            as _NoEvalBoardSettings;
    final rect = tester.getRect(toggle);
    expect(rect.right, greaterThan(1340));
    expect(rect.top, lessThan(tester.getTopLeft(find.text('Today')).dy));

    for (final (icon, mode, layout) in [
      (
        Icons.view_list_rounded,
        GamesListViewMode.chessBoard,
        DesktopCardLayout.list,
      ),
      (
        Icons.grid_view_rounded,
        GamesListViewMode.chessBoardGrid,
        DesktopCardLayout.grid,
      ),
      (
        Icons.view_agenda_outlined,
        GamesListViewMode.gamesCard,
        DesktopCardLayout.compact,
      ),
    ]) {
      await tester.tap(
        find.descendant(of: toggle, matching: find.byIcon(icon)),
      );
      await tester.pump();
      expect(container.read(gamesListViewModeProvider), mode);
      expect(
        tester
            .widgetList<DesktopGameCard>(find.byType(DesktopGameCard))
            .map((card) => card.layout),
        everyElement(layout),
      );
    }
    expect(settings.savedViewModes, [2, 1, 0]);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  for (final mode in GamesListViewMode.values) {
    testWidgets('${mode.name} fits a narrow desktop pane', (tester) async {
      await _pump(tester, viewMode: mode, width: 760);
      expect(tester.takeException(), isNull);
      final toggle = tester.getRect(find.byType(GameViewModeToggle));
      expect(toggle.right, lessThanOrEqualTo(740));
      expect(toggle.left, greaterThan(350));
      expect(find.byType(DesktopGameCard), findsNWidgets(3));
    });
  }

  testWidgets('scorecards carry their likes and event above each card', (
    tester,
  ) async {
    final repository = await _pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(GameViewModeToggle), findsOneWidget);
    expect(find.text('1.2K'), findsOneWidget);
    expect(find.text('31'), findsOneWidget);
    expect(find.text('Norway Chess'), findsNWidgets(3));
    expect(find.byType(DesktopGameCard), findsNWidgets(3));
    final layouts = tester
        .widgetList<DesktopGameCard>(find.byType(DesktopGameCard))
        .map((card) => card.layout);
    expect(layouts, everyElement(DesktopCardLayout.compact));
    // Week is the default. A free user sees the weekly cards exactly as
    // Premium does (no lock, no tint, menu on); the open shows the paywall.
    expect(repository.queries.single.period, CommunityLikesPeriod.week);
    expect(
      tester
          .widgetList<DesktopGameCard>(find.byType(DesktopGameCard))
          .map((card) => card.lockedReason),
      everyElement(isNull),
    );
    expect(
      tester
          .widgetList<LiveDesktopGameCard>(find.byType(LiveDesktopGameCard))
          .map((card) => card.enableContextMenu),
      everyElement(isTrue),
    );
  });

  testWidgets('grid view sets each like count on its board', (tester) async {
    await _pump(tester, viewMode: GamesListViewMode.chessBoardGrid);

    expect(tester.takeException(), isNull);
    final cards = tester.widgetList<DesktopGameCard>(
      find.byType(DesktopGameCard),
    );
    expect(
      cards.map((card) => card.layout),
      everyElement(DesktopCardLayout.grid),
    );
    final hearts =
        tester
            .widgetList<DesktopLikeCountHeart>(
              find.byType(DesktopLikeCountHeart),
            )
            .map((heart) => heart.likes)
            .toList();
    expect(hearts, [1240, 31, 4]);
    expect(cards.map((card) => card.lockedReason), everyElement(isNull));
  });

  testWidgets('list view follows the choice and gates at the click', (
    tester,
  ) async {
    await _pump(tester, viewMode: GamesListViewMode.chessBoard);

    expect(tester.takeException(), isNull);
    final cards = tester.widgetList<DesktopGameCard>(
      find.byType(DesktopGameCard),
    );
    expect(
      cards.map((card) => card.layout),
      everyElement(DesktopCardLayout.list),
    );
    expect(cards.map((card) => card.lockedReason), everyElement(isNull));
    expect(find.byType(DesktopLikeCountHeart), findsNWidgets(3));
  });

  testWidgets('the view toggle is only offered on Games', (tester) async {
    await _pump(tester);
    expect(find.byType(GameViewModeToggle), findsOneWidget);

    await tester.tap(find.text('Players'));
    await tester.pump();
    expect(find.byType(GameViewModeToggle), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets("today's ranking draws its cards unlocked", (tester) async {
    final repository = await _pump(tester);
    await tester.tap(find.text('Today'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repository.queries.last.period, CommunityLikesPeriod.today);
    final card = tester.widget<DesktopGameCard>(
      find.byType(DesktopGameCard).first,
    );
    expect(card.lockedReason, isNull);
    expect(tester.takeException(), isNull);
    // Let the pressed segment's hover and motion timers finish.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('picking a player narrows Games to their games', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Players'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Carlsen played games 1 and 2: 1240 + 31 = 1271 likes, ranked first.
    // Caruana: 1240 + 4 = 1244, also 1.2K; Gukesh 31 + 4 = 35.
    expect(find.text('1.2K'), findsNWidgets(2));
    expect(find.text('35'), findsOneWidget);

    await tester.tap(find.text('Gukesh D'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.text('Games with Gukesh D', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(DesktopGameCard), findsNWidgets(2));
    expect(find.text('All games'), findsOneWidget);

    await tester.tap(find.text('All games'));
    await tester.pump();
    expect(find.byType(DesktopGameCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('empty, not-live and About states render', (tester) async {
    await _pump(tester, result: const CommunityLikesResult.ranked([]));
    // Every fallback ranking is empty too, so the message stays.
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('No games liked in this period'), findsOneWidget);

    await tester.tap(find.text('About'));
    await tester.pump();
    expect(find.text('Games the community loves.'), findsOneWidget);
    expect(find.text('Open Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('an empty week falls back to the month that has games', (
    tester,
  ) async {
    final repository = await _pump(
      tester,
      byPeriod: {
        CommunityLikesPeriod.week: const CommunityLikesResult.ranked([]),
      },
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      repository.queries.map((query) => query.period),
      containsAllInOrder([
        CommunityLikesPeriod.week,
        CommunityLikesPeriod.month,
      ]),
    );
    expect(find.text('No games liked in this period'), findsNothing);
    expect(find.byType(DesktopGameCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  for (final section in ['Games', 'Players']) {
    for (final period in [
      CommunityLikesPeriod.today,
      CommunityLikesPeriod.week,
    ]) {
      testWidgets('$section keeps a manually selected empty ${period.name}', (
        tester,
      ) async {
        await _pump(
          tester,
          byPeriod: {
            CommunityLikesPeriod.week: const CommunityLikesResult.ranked([]),
            CommunityLikesPeriod.today: const CommunityLikesResult.ranked([]),
          },
        );
        await tester.pump(const Duration(milliseconds: 50));
        final container = ProviderScope.containerOf(
          tester.element(find.byType(DesktopLikesPane)),
        );
        // Preserve the initial automatic choice, then exercise real controls.
        expect(
          container.read(communityLikesPeriodProvider),
          CommunityLikesPeriod.month,
        );
        if (section == 'Players') {
          await tester.tap(find.text('Players'));
          await tester.pump();
        }
        await tester.tap(find.text(period.label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(container.read(communityLikesPeriodProvider), period);
        expect(container.read(communityLikesDayProvider), isNull);
        expect(
          find.text(
            period == CommunityLikesPeriod.today
                ? 'No games liked yet today'
                : 'No games liked in this period',
          ),
          findsOneWidget,
        );
        expect(find.byType(DesktopGameCard), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 2));
      });
    }
  }

  testWidgets('date arrows retain an empty historical ranking', (tester) async {
    final previous =
        CommunityLikesQuery(
          CommunityLikesPeriod.month,
          DateTime.now(),
        ).previous!;
    await _pump(
      tester,
      byQuery: {previous: const CommunityLikesResult.ranked([])},
    );
    await tester.tap(find.text('Month'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopLikesPane)),
    );
    expect(
      container.read(communityLikesPeriodProvider),
      CommunityLikesPeriod.month,
    );
    expect(container.read(communityLikesDayProvider), previous.start);
    expect(find.text(previous.label(DateTime.now())), findsOneWidget);
    expect(find.text('No games liked in this period'), findsOneWidget);
    expect(find.byType(DesktopGameCard), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  for (final returnToWeek in [false, true]) {
    testWidgets(
      'manual ${returnToWeek ? 'Today to Week' : 'active Week'} cancels a pending fallback',
      (tester) async {
        final month = Completer<CommunityLikesResult>();
        final repository = await _pump(
          tester,
          byPeriod: {
            CommunityLikesPeriod.week: const CommunityLikesResult.ranked([]),
            CommunityLikesPeriod.today: const CommunityLikesResult.ranked([]),
          },
          pendingByPeriod: {CommunityLikesPeriod.month: month.future},
        );
        expect(
          repository.queries.map((q) => q.period),
          contains(CommunityLikesPeriod.month),
        );
        if (returnToWeek) {
          await tester.tap(find.text('Today'));
          await tester.pump();
        }
        await tester.tap(find.text('Week'));
        await tester.pump();
        month.complete(const CommunityLikesResult.ranked([]));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final container = ProviderScope.containerOf(
          tester.element(find.byType(DesktopLikesPane)),
        );
        expect(
          container.read(communityLikesPeriodProvider),
          CommunityLikesPeriod.week,
        );
        expect(
          repository.queries.any((q) => q.period == CommunityLikesPeriod.year),
          isFalse,
        );
        expect(find.text('No games liked in this period'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  testWidgets('a later empty refresh does not restart initial auto-selection', (
    tester,
  ) async {
    final byPeriod = <CommunityLikesPeriod, CommunityLikesResult>{};
    final repository = await _pump(tester, byPeriod: byPeriod);
    expect(find.byType(DesktopGameCard), findsNWidgets(3));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopLikesPane)),
    );
    final query = CommunityLikesQuery(
      CommunityLikesPeriod.week,
      DateTime.now(),
    );
    byPeriod[CommunityLikesPeriod.week] = const CommunityLikesResult.ranked([]);
    container.invalidate(communityLikesProvider(query));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      container.read(communityLikesPeriodProvider),
      CommunityLikesPeriod.week,
    );
    expect(
      repository.queries.every((q) => q.period == CommunityLikesPeriod.week),
      isTrue,
    );
    expect(find.text('No games liked in this period'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a backend without the ranking says so', (tester) async {
    await _pump(tester, result: const CommunityLikesResult.notLive());
    expect(find.text('Rankings are not live yet'), findsOneWidget);
  });

  test('section provider defaults to Games', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(communityLikesSectionProvider),
      CommunityLikesSection.games,
    );
    expect(DesktopCardLayout.compact, isNotNull);
  });
}
