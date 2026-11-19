// Regression coverage for daily scores, refreshes and disclosure state scopes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';

const _semi = 'qEXour3L';
const _final = '6PTzCQFL';
final _active = StateProvider((ref) => 0);
final _games = StateProvider<List<GamesTourModel>>(
  (ref) => throw UnimplementedError(),
);
PlayerCard _player(String name) => PlayerCard(
  name: name,
  federation: 'USA',
  title: 'GM',
  rating: 2700,
  countryCode: 'USA',
  team: null,
);
GamesTourModel _game(int n, GameStatus status) => GamesTourModel(
  gameId: 'qa-$n',
  whitePlayer: _player('Alpha, Anna'),
  blackPlayer: _player('Beta, Boris'),
  whiteTimeDisplay: '05:00',
  blackTimeDisplay: '05:00',
  whiteClockCentiseconds: 30000,
  blackClockCentiseconds: 30000,
  gameStatus: status,
  roundId: 'source-$n',
  roundSlug: 'game-$n-blitz',
  tourId: _semi,
);
GroupedGamesData _grouped(List<GamesTourModel> games) {
  final round = GamesAppBarModel(
    id: 'qa-stage',
    name: 'QA stage',
    startsAt: DateTime.utc(2026, 11, 17),
    roundStatus: RoundStatus.completed,
  );
  return GroupedGamesData(
    filteredRounds: [round],
    gamesByRound: {round.id: games},
    isKnockoutTournament: true,
    isMultiStageKnockout: false,
    isLoading: false,
    rounds: [round],
    allGames: games,
    providerGameCount: games.length,
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<GamesTourModel> games, {
  List<String> tours = const [_semi],
}) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      _games.overrideWith((ref) => games),
      gamesTourProvider.overrideWith((ref, id) => _Idle()),
      boardSettingsProviderNew.overrideWith(_Board.new),
      engineSettingsProviderNew.overrideWith(_Engine.new),
      gamesListViewModeProvider.overrideWithValue(
        GamesListViewMode.chessBoardGrid,
      ),
      desktopGameIsPastProvider.overrideWith((ref, id) => false),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Consumer(
          builder:
              (context, ref, child) => Scaffold(
                body: IndexedStack(
                  index: ref.watch(_active),
                  children: [
                    for (var i = 0; i < tours.length; i++)
                      ProviderScope(
                        key: ValueKey('qa-pane-$i'),
                        overrides: [
                          gamesTourGroupedProvider.overrideWith(
                            (ref) => _grouped(
                              ref
                                  .watch(_games)
                                  .map(
                                    (game) => game.copyWith(tourId: tours[i]),
                                  )
                                  .toList(),
                            ),
                          ),
                          gamesTourScreenProvider.overrideWith(
                            (ref) => _Screen(ref),
                          ),
                        ],
                        child: TournamentGamesView(
                          tabId: 'qa-tab-$i',
                          tournamentId: tours[i],
                        ),
                      ),
                  ],
                ),
              ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Set<String> _mounted(WidgetTester tester) =>
    tester
        .widgetList<DesktopGameCard>(find.byType(DesktopGameCard))
        .map((card) => card.data.id)
        .toSet();
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

List<Color?> _colors(WidgetTester tester, String text) =>
    ((tester.widget<Text>(find.text(text)).textSpan as TextSpan).children!)
        .whereType<TextSpan>()
        .map((span) => span.style?.color)
        .toList();
void main() {
  testWidgets('Total Chess QA tied and reversed-color day scores', (
    tester,
  ) async {
    final second = _game(8, GameStatus.whiteWins).copyWith(
      whitePlayer: _player('Beta, Boris'),
      blackPlayer: _player('Alpha, Anna'),
    );
    await _pump(tester, [_game(1, GameStatus.draw), second]);
    expect(_colors(tester, '½–½'), [kWhiteColor, kWhiteColor70, kWhiteColor]);
    expect(_colors(tester, '0–1'), [kRedColor, kWhiteColor70, kPrimaryColor]);
    expect(find.text('Armageddon'), findsNothing);
    await _finish(tester);
  });
  testWidgets('Total Chess QA refresh reordering retains the folded day', (
    tester,
  ) async {
    final first = _game(1, GameStatus.whiteWins);
    final future = _game(8, GameStatus.ongoing);
    final container = await _pump(tester, [first, future]);
    await tester.tap(find.text('Day 1'));
    await tester.pump();
    expect(_mounted(tester), {'qa-8'});
    container.read(_games.notifier).state = [
      future.copyWith(lastMove: 'e2e4'),
      first,
    ];
    await tester.pump();
    expect(_mounted(tester), {'qa-8'});
    expect(find.text('1–0'), findsOneWidget);
    final labels =
        tester
            .widgetList<Text>(find.byType(Text))
            .where((text) => text.data == 'Day 1' || text.data == 'Day 2')
            .map((text) => text.data)
            .toList();
    expect(labels, ['Day 2', 'Day 1']);
    await tester.tap(find.text('Day 1'));
    await tester.pump();
    expect(_mounted(tester), {'qa-1', 'qa-8'});
    await _finish(tester);
  });
  testWidgets(
    'Total Chess QA different events isolate identical match day keys',
    (tester) async {
      final container = await _pump(
        tester,
        [_game(1, GameStatus.draw), _game(8, GameStatus.whiteWins)],
        tours: [_semi, _final],
      );
      await tester.tap(find.text('Day 1'));
      await tester.pump();
      expect(_mounted(tester), {'qa-8'});
      container.read(_active.notifier).state = 1;
      await tester.pump();
      expect(_mounted(tester), {'qa-1', 'qa-8'});
      await tester.tap(find.text('Day 2'));
      await tester.pump();
      expect(_mounted(tester), {'qa-1'});
      container.read(_active.notifier).state = 0;
      await tester.pump();
      expect(_mounted(tester), {'qa-8'});
      container.read(_active.notifier).state = 1;
      await tester.pump();
      expect(_mounted(tester), {'qa-1'});
      await _finish(tester);
    },
  );
  testWidgets('Total Chess QA duplicate event tabs share day choices', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      [_game(1, GameStatus.draw), _game(8, GameStatus.whiteWins)],
      tours: [_semi, _semi],
    );
    await tester.tap(find.text('Day 1'));
    await tester.pump();
    container.read(_active.notifier).state = 1;
    await tester.pump();
    expect(_mounted(tester), {'qa-8'});
    await tester.tap(find.text('Day 1'));
    await tester.pump();
    container.read(_active.notifier).state = 0;
    await tester.pump();
    expect(_mounted(tester), {'qa-1', 'qa-8'});
    await _finish(tester);
  });
}

class _Idle extends StateNotifier<AsyncValue<List<Games>>>
    implements GamesTourNotifier {
  _Idle() : super(const AsyncData([]));
  @override
  void setDesktopPollingConsumer({
    required String consumerId,
    required bool active,
  }) {}
  @override
  void removeDesktopPollingConsumer(String consumerId) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Screen extends GamesTourScreenProvider {
  _Screen(Ref ref) : super.loading(ref: ref) {
    state = AsyncData(
      GamesScreenModel(
        gamesTourModels: [],
        pinnedGamedIs: [],
        isSearchMode: false,
      ),
    );
  }
}

class _Board extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(showEvaluationBar: false);
}

class _Engine extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineGauge: false);
}
