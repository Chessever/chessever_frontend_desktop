import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/player_score_card_view.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/providers/player_ratings_provider.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'event_player_board_scope_test.dart' as fixture;

class _Tours implements TourRepository {
  @override
  Future<List<Tour>> getTourByGroupId(String id) async => [
    Tour(
      id: 'event-a',
      name: 'Event A',
      slug: 'event-a',
      info: TourInfo.fromJson({}),
      createdAt: DateTime(2026),
      url: '',
      tier: 0,
      dates: [],
      players: [],
      groupBroadcastId: 'parent-a',
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Games implements GameRepository {
  @override
  Future<Games> getGameWithPGN(String id) async => throw StateError('offline');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History extends EventPlayerGamesNotifier {
  @override
  Future<List<GamesTourModel>> build(EventPlayerGamesKey key) async => [
    for (var round = 1; round <= 9; round++) fixture.model(round),
  ];
}

void main() {
  testWidgets('expanded card row retains scope and heading is passive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const player = PlayerStandingModel(
      name: 'Player',
      fideId: 101,
      countryCode: '',
      title: '',
      score: 2500,
      scoreChange: 0,
      matchScore: '7 / 9',
    );
    final games = [
      for (var round = 1; round <= 9; round++) fixture.model(round),
    ];
    final container = ProviderContainer(
      overrides: [
        backfilledStandingPlayerProvider.overrideWith(
          (ref, player) async => player,
        ),
        allRatingsProvider.overrideWith(
          (ref, request) async => const AllRatingsResult(standard: 2500),
        ),
        eventPlayerGamesProvider.overrideWith(_History.new),
        tourRepositoryProvider.overrideWithValue(_Tours()),
        gameRepositoryProvider.overrideWithValue(_Games()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return Scaffold(
                body: PlayerScoreCardView(
                  player: player,
                  tabContext: PlayerScoreCardTabContext(
                    hasEventContext: true,
                    profileDataSource: PlayerProfileDataSource.supabase,
                    gamesContext: games,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Exercise the production row callback, not a hand-built Board destination.
    final dynamic row =
        tester
            .widgetList(
              find.byWidgetPredicate(
                (widget) => widget.runtimeType.toString() == '_GameRow',
              ),
            )
            .first;
    final GamesTourModel clicked = row.game as GamesTourModel;
    row.onTap();
    await tester.pumpAndSettle();
    final firstId = container.read(desktopTabsProvider).activeId!;
    final first = container.read(boardTabGameArgsByTabIdProvider)[firstId]!;
    expect(first.gameId, clicked.gameId);
    expect(first.eventGamesKey, isNull);
    expect(first.eventPlayerScope?.playerName, 'Player');
    expect(first.eventPlayerScope?.fideId, 101);
    expect(first.eventGames, hasLength(9));
    expect(first.eventBroadcastId, 'parent-a');
    expect(first.viewSource, ChessboardView.tour);
    expect(first.label, startsWith('Player · '));
    expect(
      tester.widgetList<DesktopHeaderActionButton>(
        find.byType(DesktopHeaderActionButton),
      ).where((w) => w.label == 'Tournament games'),
      isEmpty,
    );
    await tester.tap(find.text('Tournament games'));
    await tester.pumpAndSettle();
    expect(container.read(desktopTabsProvider).activeId, firstId);
    expect(find.text('Open player profile'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
