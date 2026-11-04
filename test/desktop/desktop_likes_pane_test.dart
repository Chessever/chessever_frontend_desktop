import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/desktop_likes_pane.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/services/likes/community_likes_repository.dart';
import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:chessever/desktop/widgets/desktop_lock_reasons.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/responsive_helper.dart';

import 'support/collections_fakes.dart';

const _kFen =
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

class _FakeRepository implements CommunityLikesRepository {
  _FakeRepository(this.result);

  final CommunityLikesResult result;
  final List<CommunityLikesQuery> queries = [];

  @override
  Future<CommunityLikesResult> fetch(
    CommunityLikesQuery query, {
    int limit = kCommunityLikesPageSize,
    CommunityLikesCursor? after,
  }) async {
    queries.add(query);
    return result;
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
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: false);
    state = const AsyncValue.data(settings);
    return settings;
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
  SubscriptionState? subscription,
}) async {
  tester.view.physicalSize = const Size(1280, 820);
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
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        communityLikesRepositoryProvider.overrideWithValue(repository),
        subscriptionProvider.overrideWith(
          (ref) => FakeSubscription(subscription ?? SubscriptionState()),
        ),
        gameStreamRepositoryProvider.overrideWithValue(_FakeGameStream()),
        boardSettingsProviderNew.overrideWith(_NoEvalBoardSettings.new),
        engineSettingsProviderNew.overrideWith(_NoGaugeEngineSettings.new),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return const Scaffold(body: DesktopLikesPane(tabId: 'likes-1'));
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
  testWidgets('ranks games with their likes beside each card', (tester) async {
    final repository = await _pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Likes'), findsWidgets);
    expect(find.text('1.2K'), findsOneWidget);
    expect(find.text('31'), findsOneWidget);
    expect(find.byType(DesktopGameCard), findsNWidgets(3));
    // Week is the default: a weekly ranking is browsable but locked to open.
    expect(repository.queries.single.period, CommunityLikesPeriod.week);
    final card = tester.widget<DesktopGameCard>(
      find.byType(DesktopGameCard).first,
    );
    expect(card.lockedReason, kCommunityLikesLockedReason);
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
    expect(find.text('No games liked in this period'), findsOneWidget);

    await tester.tap(find.text('About'));
    await tester.pump();
    expect(find.text('Games the community loves.'), findsOneWidget);
    expect(find.text('Open Library'), findsOneWidget);
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
