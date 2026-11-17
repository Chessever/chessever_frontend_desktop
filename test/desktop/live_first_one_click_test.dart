import 'package:chessever/desktop/panes/countrymen_pane.dart';
import 'package:chessever/desktop/panes/favorites_pane.dart';
import 'package:chessever/desktop/state/game_list_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/game_view_mode_toggle.dart';
import 'package:chessever/desktop/widgets/live_first_mark.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
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

GamesTourModel _game(String id, GameStatus status, {DateTime? lastMoveTime}) {
  PlayerCard player(String name) => PlayerCard(
    name: name,
    federation: 'AZE',
    title: 'GM',
    rating: 2700,
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
