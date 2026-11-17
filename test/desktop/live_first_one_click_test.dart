import 'support/current_broadcast_games.dart';

import 'package:chessever/desktop/panes/countrymen_pane.dart';
import 'package:chessever/desktop/panes/favorites_pane.dart';
import 'package:chessever/desktop/state/game_list_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_date_group_card.dart';
import 'package:chessever/desktop/widgets/desktop_quick_list_toggles.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/live_first_mark.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show LiveDesktopGameCard;
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_combined_games_provider.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_mode_provider.dart';
import 'package:chessever/screens/favorites/favorite_players_provider.dart';
import 'package:chessever/screens/favorites/player_games/provider/favorites_combined_games_provider.dart';
import 'package:chessever/screens/favorites/provider/favorites_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('the Live first mark is centred on its box', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: key,
          child: const LiveFirstMark(size: 160, color: Color(0xFFFFFFFF)),
        ),
      ),
    );

    late Rect ink;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData();
      final bytes = data!.buffer.asUint8List();
      var left = image.width, top = image.height, right = -1, bottom = -1;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (bytes[(y * image.width + x) * 4 + 3] < 128) continue;
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
      ink = Rect.fromLTRB(
        left.toDouble(),
        top.toDouble(),
        right + 1.0,
        bottom + 1.0,
      );
    });

    // Ink must sit on the box's centre on both axes, as on the web.
    expect(ink.center.dx, closeTo(80, 1));
    expect(ink.center.dy, closeTo(80, 1));
    // The two arcs reach out to the web's 2..14 horizontal ink span.
    expect(ink.width, closeTo(120, 3));
  });

  testWidgets(
    'Live first with nothing in play says so and stays off; with a live game '
    'it turns on, and a second press turns it off',
    (tester) async {
      var games = <GamesTourModel>[];
      await tester.pumpWidget(
        _app(
          Consumer(
            builder:
                (context, ref, _) => TextButton(
                  onPressed:
                      () => pressGameListLiveFirst(
                        context: context,
                        ref: ref,
                        surface: GameListLiveFirstSurface.countrymen,
                        games: games,
                      ),
                  child: const Text('press'),
                ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.text('press')),
      );
      bool liveFirst() => container.read(
        gameListLiveFirstProvider(GameListLiveFirstSurface.countrymen),
      );

      await tester.tap(find.text('press'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(kNoLiveGamesRightNowMessage), findsOneWidget);
      expect(liveFirst(), isFalse);
      await tester.pump(const Duration(seconds: 3));

      games = [
        _game('finished', GameStatus.draw),
        _game('live', GameStatus.ongoing, lastMoveTime: DateTime.now()),
      ];
      await tester.tap(find.text('press'));
      await tester.pump();
      expect(liveFirst(), isTrue);
      expect(
        container.read(
          gameListLiveFirstProvider(GameListLiveFirstSurface.favorites),
        ),
        isFalse,
        reason: 'Each list keeps its own choice.',
      );

      await tester.tap(find.text('press'));
      await tester.pump();
      expect(liveFirst(), isFalse);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'Countrymen carries Live first, Classical, Filters and the layout on the '
    'tabs row, above the search',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifier = _FakeCountrymen(
        CountrymenCombinedGamesState(
          countryCode: 'AZ',
          countryName: 'Azerbaijan',
          hasMore: false,
        ),
      );
      await tester.pumpWidget(
        _app(
          const CountrymenPane(),
          overrides: [
            effectiveCountryProvider.overrideWithValue(
              AsyncValue.data(CountryService().findByCode('AZ')!),
            ),
            countrymenCombinedGamesProvider.overrideWith((ref) => notifier),
          ],
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CountrymenPane)),
      );
      container.read(selectedCountrymenModeProvider.notifier).state =
          CountrymenScreenMode.games;
      await tester.pump(const Duration(seconds: 1));

      final liveFirst = find.byKey(const ValueKey('countrymen-live-first'));
      final classical = find.byKey(const ValueKey('countrymen-classical-only'));
      expect(liveFirst, findsOneWidget);
      expect(classical, findsOneWidget);
      expect(find.text('Filters'), findsOneWidget);
      expect(find.byType(GameViewModeToggle), findsOneWidget);

      final tabRow = tester.getCenter(find.text('Games')).dy;
      final search = tester.getRect(find.byType(DesktopSearchField));
      for (final control in [
        liveFirst,
        classical,
        find.text('Filters'),
        find.byType(GameViewModeToggle),
      ]) {
        expect(tester.getCenter(control).dy, closeTo(tabRow, 2));
        expect(tester.getRect(control).bottom, lessThan(search.top));
      }

      await tester.tap(classical);
      await tester.pump();
      expect(
        notifier.state.filter.timeControl,
        GameTimeControlFilter.classical,
      );
      expect(find.text('1'), findsOneWidget, reason: 'Filters counts it.');

      await tester.tap(classical);
      await tester.pump();
      expect(notifier.state.filter.timeControl, GameTimeControlFilter.all);

      container.read(selectedCountrymenModeProvider.notifier).state =
          CountrymenScreenMode.events;
      await tester.pump(const Duration(seconds: 1));
      expect(liveFirst, findsNothing);
      expect(classical, findsNothing);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('Favorites carries the Games controls beside its title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _FakeFavorites(
      FavoritesCombinedGamesState(hasMore: false),
    );
    await tester.pumpWidget(
      _app(
        const FavoritesPane(),
        overrides: [
          favoritePlayersNotifierProvider.overrideWith(
            _FakeFavoritePlayers.new,
          ),
          favoritesCombinedGamesProvider.overrideWith((ref) => notifier),
        ],
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FavoritesPane)),
    );
    container.read(selectedFavoritesModeProvider.notifier).state =
        FavoritesScreenMode.games;
    await tester.pump(const Duration(seconds: 1));

    // The pane title is the first "Favorites"; the tab is the second.
    final title = tester.getRect(find.text('Favorites').first);
    final liveFirst = find.byKey(const ValueKey('favorites-live-first'));
    final classical = find.byKey(const ValueKey('favorites-classical-only'));
    final search = tester.getRect(find.byType(DesktopSearchField));
    expect(tester.getRect(liveFirst).left, greaterThan(title.right));
    for (final control in [liveFirst, classical, find.text('Filters')]) {
      expect(tester.getCenter(control).dy, closeTo(title.center.dy, 2));
      expect(tester.getRect(control).bottom, lessThan(search.top));
    }

    await tester.tap(classical);
    await tester.pump();
    expect(notifier.state.filter.timeControl, GameTimeControlFilter.classical);

    container.read(selectedFavoritesModeProvider.notifier).state =
        FavoritesScreenMode.players;
    await tester.pump(const Duration(seconds: 1));
    expect(liveFirst, findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('each quick toggle is one Tab stop, and the next Tab leaves it', (
    tester,
  ) async {
    final next = FocusNode(debugLabel: 'after the toggles');
    addTearDown(next.dispose);
    await tester.pumpWidget(
      _app(
        Row(
          children: [
            DesktopLiveFirstButton(pressed: false, onPress: () {}),
            DesktopClassicalOnlyButton(pressed: true, onPress: () {}),
            Focus(
              focusNode: next,
              child: const SizedBox(width: 20, height: 20),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // The stop is the toggle itself, wrapping its tooltip: never the
    // tooltip's own focus node inside it.
    void expectFocusOn(String label) {
      final focused = FocusManager.instance.primaryFocus!.context!;
      final stop = find.byElementPredicate((e) => identical(e, focused));
      expect(
        find.descendant(of: stop, matching: find.byType(DesktopTooltip)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: stop, matching: find.text(label)),
        findsOneWidget,
      );
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expectFocusOn('Live first');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expectFocusOn('Classical');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(next.hasPrimaryFocus, isTrue);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'Enter, numpad Enter and Space press a quick toggle, with the browser key '
    'map too, and Cmd/Ctrl+Shift+F still reaches global search',
    (tester) async {
      var presses = 0;
      var searches = 0;
      Future<void> pumpWith(Map<ShortcutActivator, Intent> appShortcuts) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              // A fresh app per key map, so focus starts from nothing.
              key: UniqueKey(),
              shortcuts: appShortcuts,
              home: Scaffold(
                body: Shortcuts(
                  shortcuts: const {
                    SingleActivator(
                          LogicalKeyboardKey.keyF,
                          meta: true,
                          shift: true,
                        ):
                        _SearchIntent(),
                    SingleActivator(
                          LogicalKeyboardKey.keyF,
                          control: true,
                          shift: true,
                        ):
                        _SearchIntent(),
                  },
                  child: Actions(
                    actions: {
                      _SearchIntent: CallbackAction<_SearchIntent>(
                        onInvoke: (_) => searches++,
                      ),
                    },
                    child: Center(
                      child: DesktopLiveFirstButton(
                        pressed: false,
                        onPress: () => presses++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }

      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }

      // The browser build's app map: Enter is a ButtonActivateIntent there.
      await pumpWith(const {
        SingleActivator(LogicalKeyboardKey.space): PrioritizedIntents(
          orderedIntents: [
            ActivateIntent(),
            ScrollIntent(
              direction: AxisDirection.down,
              type: ScrollIncrementType.page,
            ),
          ],
        ),
        SingleActivator(LogicalKeyboardKey.enter): ButtonActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ButtonActivateIntent(),
        SingleActivator(LogicalKeyboardKey.tab): NextFocusIntent(),
      });
      await press(LogicalKeyboardKey.enter);
      expect(presses, 1);
      await press(LogicalKeyboardKey.numpadEnter);
      expect(presses, 2);
      await press(LogicalKeyboardKey.space);
      expect(presses, 3);
      Actions.invoke(
        FocusManager.instance.primaryFocus!.context!,
        const ButtonActivateIntent(),
      );
      expect(presses, 4);

      // An app map with no activation keys at all: the toggle binds its own.
      await pumpWith(const {
        SingleActivator(LogicalKeyboardKey.tab): NextFocusIntent(),
      });
      await press(LogicalKeyboardKey.enter);
      await press(LogicalKeyboardKey.numpadEnter);
      await press(LogicalKeyboardKey.space);
      expect(presses, 7);

      for (final modifier in [
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.controlLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(modifier);
      }
      expect(searches, 2);
      expect(presses, 7);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Countrymen Live first: nothing in play says so; a live game then leads '
    'Today',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifier = _FakeCountrymen(
        CountrymenCombinedGamesState(
          countryCode: 'AZ',
          countryName: 'Azerbaijan',
          hasMore: false,
        ),
      );
      await tester.pumpWidget(
        _app(
          const CountrymenPane(),
          overrides: [
            ..._liveCardOverrides(),
            effectiveCountryProvider.overrideWithValue(
              AsyncValue.data(CountryService().findByCode('AZ')!),
            ),
            countrymenCombinedGamesProvider.overrideWith((ref) => notifier),
          ],
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CountrymenPane)),
      );
      container.read(selectedCountrymenModeProvider.notifier).state =
          CountrymenScreenMode.games;
      await tester.pump(const Duration(seconds: 1));

      await _expectLiveFirstPressFlow(
        tester,
        button: find.byKey(const ValueKey('countrymen-live-first')),
        liveFirst:
            () => container.read(
              gameListLiveFirstProvider(GameListLiveFirstSurface.countrymen),
            ),
        seed: (games) => notifier.state = notifier.state.copyWith(games: games),
      );
    },
  );

  testWidgets(
    'Favorites Live first: nothing in play says so; a live game then leads '
    'Today',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifier = _FakeFavorites(
        FavoritesCombinedGamesState(hasMore: false),
      );
      await tester.pumpWidget(
        _app(
          const FavoritesPane(),
          overrides: [
            ..._liveCardOverrides(),
            favoritePlayersNotifierProvider.overrideWith(
              _FakeFavoritePlayers.new,
            ),
            favoritesCombinedGamesProvider.overrideWith((ref) => notifier),
          ],
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FavoritesPane)),
      );
      container.read(selectedFavoritesModeProvider.notifier).state =
          FavoritesScreenMode.games;
      await tester.pump(const Duration(seconds: 1));

      await _expectLiveFirstPressFlow(
        tester,
        button: find.byKey(const ValueKey('favorites-live-first')),
        liveFirst:
            () => container.read(
              gameListLiveFirstProvider(GameListLiveFirstSurface.favorites),
            ),
        seed: (games) => notifier.state = notifier.state.copyWith(games: games),
      );
    },
  );

  testWidgets('the layout switcher shows bare glyphs, no tile behind them', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const GameViewModeToggle()));
    await tester.pump();

    final decorated = find.descendant(
      of: find.byType(GameViewModeToggle),
      matching: find.byWidgetPredicate(
        (widget) =>
            (widget is Container && widget.decoration != null) ||
            widget is DecoratedBox ||
            widget is AnimatedContainer,
      ),
    );
    expect(decorated, findsNothing);

    final grid = tester.widget<Icon>(find.byIcon(Icons.grid_view_rounded));
    final list = tester.widget<Icon>(find.byIcon(Icons.view_list_rounded));
    expect(grid.color, kPrimaryColor);
    expect(list.color, kWhiteColor70);
  });
}

Widget _app(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [
      gamesListViewModeProvider.overrideWithValue(
        GamesListViewMode.chessBoardGrid,
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: AppTheme.darkTheme,
      home: FTheme(
        data: FThemes.zinc.dark,
        child: FToaster(child: Scaffold(body: child)),
      ),
    ),
  );
}

GamesTourModel _game(
  String id,
  GameStatus status, {
  DateTime? lastMoveTime,
  int rating = 2700,
}) {
  PlayerCard player(String name) => PlayerCard(
    name: name,
    federation: 'AZE',
    title: 'GM',
    rating: rating,
    countryCode: 'AZ',
    team: null,
  );
  return GamesTourModel(
    gameId: id,
    whitePlayer: player('White $id'),
    blackPlayer: player('Black $id'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-$id',
    tourId: 'tour-$id',
    gameDay: DateTime.now(),
    lastMoveTime: lastMoveTime,
  );
}

/// Presses a pane's Live first with nothing in play (a toast, and it stays
/// off), then seeds a finished game that out-rates a live one and presses
/// again: the toggle turns on and the live game moves to the top of Today.
Future<void> _expectLiveFirstPressFlow(
  WidgetTester tester, {
  required Finder button,
  required bool Function() liveFirst,
  required void Function(List<GamesTourModel> games) seed,
}) async {
  expect(button, findsOneWidget);
  await tester.tap(button);
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text(kNoLiveGamesRightNowMessage), findsOneWidget);
  expect(liveFirst(), isFalse);
  await tester.pump(const Duration(seconds: 3));

  seed([
    _game('finished', GameStatus.draw, rating: 2800),
    _game(
      'live',
      GameStatus.ongoing,
      rating: 2600,
      lastMoveTime: DateTime.now(),
    ),
  ]);
  await tester.pump(const Duration(seconds: 1));
  expect(
    [
      for (final day in tester.widgetList<DesktopDateGroupCard>(
        find.byType(DesktopDateGroupCard),
      ))
        day.label,
    ],
    ['Today'],
  );
  // By rating, the finished game leads the day until Live first is on.
  expect(_listedGameIds(tester), ['finished', 'live']);

  await tester.tap(button);
  await tester.pump(const Duration(seconds: 1));
  expect(liveFirst(), isTrue);
  expect(find.text(kNoLiveGamesRightNowMessage), findsNothing);
  expect(_listedGameIds(tester), ['live', 'finished']);

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 3));
}

/// Game ids of the cards on screen, in reading order.
List<String> _listedGameIds(WidgetTester tester) => [
  for (final card in tester.widgetList<LiveDesktopGameCard>(
    find.byType(LiveDesktopGameCard),
  ))
    card.game.gameId,
];

/// Lets a pane mount real game cards offline: no Realtime, no engine.
List<Override> _liveCardOverrides() => [
  currentBroadcastGames,
  gameStreamRepositoryProvider.overrideWithValue(_SilentGameStreamRepository()),
  boardSettingsProviderNew.overrideWith(_QuietBoardSettings.new),
  engineSettingsProviderNew.overrideWith(_QuietEngineSettings.new),
];

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _SilentGameStreamRepository extends GameStreamRepository {
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

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) => const Stream.empty();

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) => const Stream.empty();
}

class _QuietBoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _QuietEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings(showEngineGauge: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _FakeCountrymen extends StateNotifier<CountrymenCombinedGamesState>
    implements CountrymenCombinedGamesNotifier {
  _FakeCountrymen(super.state);

  @override
  void applyFilter(GameFilter filter) => state = state.copyWith(filter: filter);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeFavorites extends StateNotifier<FavoritesCombinedGamesState>
    implements FavoritesCombinedGamesNotifier {
  _FakeFavorites(super.state);

  @override
  void applyFilter(GameFilter newFilter) =>
      state = state.copyWith(filter: newFilter);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeFavoritePlayers extends FavoritePlayersNotifier {
  @override
  Future<FavoritePlayersState> build() async =>
      const FavoritePlayersState(players: [], isLoading: false);
}
