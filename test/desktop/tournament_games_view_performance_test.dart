import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_grouped_game_keyboard_focus.dart';
import 'package:chessever/desktop/widgets/round_header_card.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/knockout_match_detector.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:chessever/theme/app_theme.dart';

final _searchFocusGroupedStateProvider = StateProvider<GroupedGamesData>(
  (ref) => throw UnimplementedError(),
);

void main() {
  testWidgets('the championship opener appears first and starts expanded', (
    tester,
  ) async {
    final rounds = [
      for (final (number, date) in [
        (14, DateTime.utc(2099, 12, 11, 14)),
        (1, DateTime.utc(2099, 11, 24, 14)),
      ])
        GamesAppBarModel(
          id: 'world-match-$number',
          name: 'Game $number',
          startsAt: date,
          roundStatus: RoundStatus.upcoming,
        ),
    ];
    final games = [
      for (final round in rounds)
        GamesTourModel(
          gameId: 'game-${round.id}',
          whitePlayer: _player('Sindarov, Javokhir'),
          blackPlayer: _player('Gukesh D'),
          whiteTimeDisplay: '120:00',
          blackTimeDisplay: '120:00',
          whiteClockCentiseconds: 720000,
          blackClockCentiseconds: 720000,
          gameStatus: GameStatus.ongoing,
          roundId: round.id,
          tourId: '',
        ),
    ];
    final grouped = GroupedGamesData(
      filteredRounds: rounds,
      gamesByRound: {
        for (final game in games) game.roundId: [game],
      },
      upcomingPairingRoundIds: {for (final round in rounds) round.id},
      matchFormatHeader: KnockoutMatchDetector.createMatchHeader(
        'match',
        games,
      ),
      isKnockoutTournament: false,
      isMultiStageKnockout: false,
      isLoading: false,
      rounds: rounds,
      allGames: games,
      providerGameCount: games.length,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gamesTourGroupedProvider.overrideWith((ref) => grouped),
          gamesTourScreenProvider.overrideWith(
            (ref) => _SearchFocusGamesNotifier(ref),
          ),
          boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _EngineSettingsOffNotifier.new,
          ),
          gameStreamRepositoryProvider.overrideWithValue(
            _TrackingGameStreamRepository(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: TournamentGamesView(
              tabId: 'world-match-tab',
              tournamentId: 'world-match-tour',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final firstHeader = tester.widget<RoundHeaderCard>(
      find.byType(RoundHeaderCard).first,
    );
    expect(firstHeader.round.name, 'Game 1');
    expect(firstHeader.expanded, isTrue);
    expect(find.text('2 games · Upcoming'), findsOneWidget);

    await tester.tap(find.text('Game 1'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<RoundHeaderCard>(find.byType(RoundHeaderCard).first)
          .expanded,
      isFalse,
    );
  });

  test('only the current top round expands on first paint', () {
    expect(
      shouldInitiallyExpandTournamentRound(
        roundId: 'current',
        topRoundId: 'current',
      ),
      isTrue,
    );
    expect(
      shouldInitiallyExpandTournamentRound(
        roundId: 'historical',
        topRoundId: 'current',
      ),
      isFalse,
    );
  });

  test('hidden retained tournament panes suspend only their safety poll', () {
    expect(
      shouldRunTournamentSafetyRefresh(
        globallyEnabled: true,
        desktopManaged: false,
        desktopConsumerActivity: const <bool>[],
      ),
      isTrue,
      reason: 'Mobile/unmanaged consumers retain their existing behavior.',
    );
    expect(
      shouldRunTournamentSafetyRefresh(
        globallyEnabled: true,
        desktopManaged: true,
        desktopConsumerActivity: const <bool>[false, false],
      ),
      isFalse,
    );
    expect(
      shouldRunTournamentSafetyRefresh(
        globallyEnabled: true,
        desktopManaged: true,
        desktopConsumerActivity: const <bool>[false, true],
      ),
      isTrue,
    );
  });

  testWidgets(
    'a reordered round moves mounted cards instead of remounting them',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _TrackingGameStreamRepository();
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final games = List<GamesTourModel>.generate(12, _game, growable: false);

      Widget harness(List<GamesTourModel> roundGames) {
        return ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(
              _EvaluationBarOffNotifier.new,
            ),
            engineSettingsProviderNew.overrideWith(
              _EngineSettingsOffNotifier.new,
            ),
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                ResponsiveHelper.init(context);
                return Scaffold(
                  body: buildLazyTournamentGamesViewportForTesting(
                    games: roundGames,
                    scrollController: scrollController,
                    layout: DesktopCardLayout.compact,
                    cacheExtent: 2000,
                    scopeId: 'reorder-identity',
                  ),
                );
              },
            ),
          ),
        );
      }

      Map<String, Element> mountedCards() {
        final result = <String, Element>{};
        for (final element in find.byType(LiveDesktopGameCard).evaluate()) {
          final card = element.widget as LiveDesktopGameCard;
          result[card.game.gameId] = element;
        }
        return result;
      }

      await tester.pumpWidget(harness(games));
      await tester.pump();
      final before = mountedCards();
      expect(before.length, greaterThan(4));

      // A refresh may publish the round in a new order. Every card changes
      // index, so a delegate that cannot map a child back to its new index
      // destroys and re-inflates every card (and its Realtime subscription).
      final reordered = games.reversed.toList(growable: false);
      await tester.pumpWidget(harness(reordered));
      await tester.pump();

      final after = mountedCards();
      expect(after.length, before.length);
      var preserved = 0;
      for (final entry in after.entries) {
        final previous = before[entry.key];
        if (previous != null && identical(previous, entry.value)) preserved++;
      }
      expect(
        preserved,
        after.length,
        reason:
            'every mounted card must keep its element (and its subscription) '
            'when the round is published in a new order',
      );
    },
  );

  testWidgets(
    '1,000-game tournament mounts and streams only the viewport window',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _TrackingGameStreamRepository();
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final games = List<GamesTourModel>.generate(
        1000,
        (index) => _game(index),
        growable: false,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(
              _EvaluationBarOffNotifier.new,
            ),
            engineSettingsProviderNew.overrideWith(
              _EngineSettingsOffNotifier.new,
            ),
            gameStreamRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                ResponsiveHelper.init(context);
                return Scaffold(
                  body: buildLazyTournamentGamesViewportForTesting(
                    games: games,
                    scrollController: scrollController,
                    layout: DesktopCardLayout.compact,
                    cacheExtent: 400,
                    scopeId: 'thousand-games',
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final initiallyMounted =
          find.byType(LiveDesktopGameCard).evaluate().length;
      expect(initiallyMounted, inInclusiveRange(1, 100));
      expect(
        find.byKey(
          const ValueKey<String>(
            'tournament-lazy-card:thousand-games:game-999',
          ),
        ),
        findsNothing,
      );
      expect(repository.individualSubscriptions, 0);
      expect(repository.roundSubscriptions, 0);
      expect(repository.tourSubscriptions, 0);
      expect(repository.activeBatchSubscriptions, inInclusiveRange(1, 4));
      expect(
        repository.requestedBatchSizes,
        everyElement(inInclusiveRange(1, 25)),
      );

      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey<String>(
            'tournament-lazy-card:thousand-games:game-999',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byType(LiveDesktopGameCard).evaluate().length,
        inInclusiveRange(1, 100),
      );
      expect(repository.activeBatchSubscriptions, inInclusiveRange(1, 4));
      expect(repository.peakActiveBatchSubscriptions, lessThanOrEqualTo(8));
      expect(repository.batchSubscriptions, lessThanOrEqualTo(8));

      // Removing the viewport must release every Realtime leaf. Retained game
      // rows remain in the parent model; only offscreen subscriptions go away.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump();
      expect(repository.activeBatchSubscriptions, 0);
    },
  );

  testWidgets('tournament grid cards reserve opening for double click', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _TrackingGameStreamRepository();
    final scrollController = ScrollController();
    final selectedGameIds = <String>[];
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _EngineSettingsOffNotifier.new,
          ),
          gameStreamRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return Scaffold(
                body: buildLazyTournamentGamesViewportForTesting(
                  games: <GamesTourModel>[_game(0)],
                  scrollController: scrollController,
                  onSelectGame: selectedGameIds.add,
                  layout: DesktopCardLayout.grid,
                  scopeId: 'board-click-contract',
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final card = tester.widget<DesktopGameCard>(find.byType(DesktopGameCard));
    expect(card.onTap, isNull);
    expect(
      card.onDoubleTap,
      isNotNull,
      reason:
          'The keyboard item owns single-click selection, so the card must '
          'reserve game opening for double click.',
    );
    expect(card.dragPayload, isNotNull);

    await tester.tap(find.byType(DesktopGameCard));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selectedGameIds, <String>['game-0']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump();
    expect(repository.activeBatchSubscriptions, 0);
  });

  testWidgets(
    'search focus survives populated-to-empty results and Backspace edits text',
    (tester) async {
      final game = GamesTourModel(
        gameId: 'search-focus-game',
        whitePlayer: _player('White'),
        blackPlayer: _player('Black'),
        whiteTimeDisplay: '05:00',
        blackTimeDisplay: '05:00',
        whiteClockCentiseconds: 30000,
        blackClockCentiseconds: 30000,
        gameStatus: GameStatus.ongoing,
        roundId: 'search-focus-round',
        tourId: '',
      );
      final round = GamesAppBarModel(
        id: game.roundId,
        name: 'Round 1',
        startsAt: DateTime.utc(2026, 7, 24, 12),
        roundStatus: RoundStatus.ongoing,
      );
      final populated = GroupedGamesData(
        filteredRounds: [round],
        gamesByRound: {
          round.id: [game],
        },
        isKnockoutTournament: false,
        isMultiStageKnockout: false,
        isLoading: false,
        rounds: [round],
        allGames: [game],
        providerGameCount: 1,
      );
      final empty = GroupedGamesData(
        filteredRounds: const [],
        gamesByRound: const {},
        isKnockoutTournament: false,
        isMultiStageKnockout: false,
        isLoading: false,
        rounds: const [],
        allGames: const [],
        providerGameCount: 1,
      );
      final container = ProviderContainer(
        overrides: [
          _searchFocusGroupedStateProvider.overrideWith((ref) => populated),
          gamesTourGroupedProvider.overrideWith(
            (ref) => ref.watch(_searchFocusGroupedStateProvider),
          ),
          gamesTourScreenProvider.overrideWith(
            (ref) => _SearchFocusGamesNotifier(ref),
          ),
          boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _EngineSettingsOffNotifier.new,
          ),
          gameStreamRepositoryProvider.overrideWithValue(
            _TrackingGameStreamRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      var backNavigationCount = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Focus(
                autofocus: true,
                onKeyEvent:
                    (node, event) => handleDesktopShellBackspaceKeyEvent(
                      event: event,
                      canGoBack: true,
                      primaryFocus: FocusManager.instance.primaryFocus,
                      onBack: () => backNavigationCount += 1,
                    ),
                child: const TournamentGamesView(
                  tabId: 'search-focus-tab',
                  tournamentId: 'search-focus-tour',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final search = find.byType(TextField);
      expect(search, findsOneWidget);
      await tester.tap(search);
      await tester.enterText(search, 'definitely no matching game');
      await tester.pump(const Duration(milliseconds: 350));
      container.read(_searchFocusGroupedStateProvider.notifier).state = empty;
      await tester.pump();

      expect(
        find.text('No games match "definitely no matching game"'),
        findsOneWidget,
      );
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(
        tester.widget<TextField>(search).controller?.text,
        'definitely no matching gam',
      );
      expect(backNavigationCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
  testWidgets('one click beside the search folds and opens every round', (
    tester,
  ) async {
    GamesTourModel game(String id, String roundId) => GamesTourModel(
      gameId: id,
      whitePlayer: _player('White $id'),
      blackPlayer: _player('Black $id'),
      whiteTimeDisplay: '05:00',
      blackTimeDisplay: '05:00',
      whiteClockCentiseconds: 30000,
      blackClockCentiseconds: 30000,
      gameStatus: GameStatus.whiteWins,
      roundId: roundId,
      tourId: '',
    );
    final rounds = [
      GamesAppBarModel(
        id: 'round-2',
        name: 'Round 2',
        startsAt: DateTime.utc(2026, 7, 25, 12),
        roundStatus: RoundStatus.completed,
      ),
      GamesAppBarModel(
        id: 'round-1',
        name: 'Round 1',
        startsAt: DateTime.utc(2026, 7, 24, 12),
        roundStatus: RoundStatus.completed,
      ),
    ];
    final games = {
      'round-2': [game('g2', 'round-2')],
      'round-1': [game('g1', 'round-1')],
    };
    final grouped = GroupedGamesData(
      filteredRounds: rounds,
      gamesByRound: games,
      isKnockoutTournament: false,
      isMultiStageKnockout: false,
      isLoading: false,
      rounds: rounds,
      allGames: [for (final list in games.values) ...list],
      providerGameCount: 2,
    );
    final container = ProviderContainer(
      overrides: [
        gamesTourGroupedProvider.overrideWith((ref) => grouped),
        gamesTourScreenProvider.overrideWith(
          (ref) => _SearchFocusGamesNotifier(ref),
        ),
        boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
        engineSettingsProviderNew.overrideWith(_EngineSettingsOffNotifier.new),
        gameStreamRepositoryProvider.overrideWithValue(
          _TrackingGameStreamRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: TournamentGamesView(
              tabId: 'collapse-all-tab',
              tournamentId: 'collapse-all-tour',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    List<bool> expanded() => [
      for (final header in tester.widgetList<RoundHeaderCard>(
        find.byType(RoundHeaderCard),
      ))
        header.expanded,
    ];
    final toggle = find.byKey(
      const ValueKey<String>('tournament-games-collapse-all'),
    );

    // Only the top round opens on first paint, so the control collapses.
    expect(expanded(), [true, false]);
    expect(find.byIcon(Icons.unfold_less_rounded), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(expanded(), [false, false]);
    expect(find.byIcon(Icons.unfold_more_rounded), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(expanded(), [true, true]);
    expect(find.byIcon(Icons.unfold_less_rounded), findsOneWidget);

    // Tab from the search lands on the control as one stop, and Enter and
    // Space press it like the click.
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
        of: find.byElementPredicate((element) => identical(element, focused)),
        matching: toggle,
      ),
      findsOneWidget,
      reason: 'The stop wraps the whole control, its tooltip included.',
    );
    // The glyph is unboxed, so keyboard focus has to draw its own ring.
    final ring = find.ancestor(
      of: toggle,
      matching: find.byType(FFocusedOutline),
    );
    expect(ring, findsOneWidget);
    expect(tester.widget<FFocusedOutline>(ring).focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(expanded(), [false, false]);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(expanded(), [true, true]);
    // The next Tab leaves the control instead of stopping on its tooltip.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final next = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
        of: toggle,
        matching: find.byElementPredicate(
          (element) => identical(element, next),
        ),
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    // Drain the tooltip's exit timer the taps started.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'Total Chess days fold independently without removing their scores',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final alpha = _player('Alpha, Anna');
      final beta = _player('Beta, Boris');
      final games = [
        for (final (id, slug) in [
          ('day-one-game', 'game-1-blitz'),
          ('day-two-game', 'game-8-blitz'),
          ('arm-game', 'armageddon'),
        ])
          _game(0).copyWith(
            gameId: id,
            tourId: 'qEXour3L',
            roundId: 'source-$slug',
            roundSlug: slug,
            whitePlayer: alpha,
            blackPlayer: beta,
            gameStatus: GameStatus.whiteWins,
          ),
      ];
      final round = GamesAppBarModel(
        id: 'semifinal-stage',
        name: 'Semifinals',
        startsAt: DateTime.utc(2026, 11, 17, 12),
        roundStatus: RoundStatus.completed,
      );
      final grouped = GroupedGamesData(
        filteredRounds: [round],
        gamesByRound: {round.id: games},
        isKnockoutTournament: true,
        isMultiStageKnockout: false,
        isLoading: false,
        rounds: [round],
        allGames: games,
        providerGameCount: games.length,
      );
      final container = ProviderContainer(
        overrides: [
          gamesTourGroupedProvider.overrideWith((ref) => grouped),
          gamesTourScreenProvider.overrideWith(
            (ref) => _SearchFocusGamesNotifier(ref),
          ),
          gamesTourProvider.overrideWith((ref, id) => _NoPollingGames()),
          boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _EngineSettingsOffNotifier.new,
          ),
          gameStreamRepositoryProvider.overrideWithValue(
            _TrackingGameStreamRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: TournamentGamesView(
                tabId: 'daily-disclosures',
                tournamentId: 'qEXour3L',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      Set<String> mountedIds() => {
        for (final card in tester.widgetList<DesktopGameCard>(
          find.byType(DesktopGameCard),
        ))
          card.data.id,
      };
      expect(mountedIds(), {'day-one-game', 'day-two-game', 'arm-game'});
      expect(find.text('1–0'), findsNWidgets(2));
      final score = tester.widget<Text>(find.text('1–0').first);
      final scoreSpan = score.textSpan as TextSpan?;
      expect(
        scoreSpan?.children
                ?.whereType<TextSpan>()
                .map((span) => span.style?.color)
                .toList() ??
            [score.style?.color],
        [kPrimaryColor, kWhiteColor70, kRedColor],
        reason: 'Each daily score side uses its own numeric result color.',
      );
      await tester.tap(find.text('Day 1'));
      await tester.pump();
      expect(mountedIds(), {'day-two-game', 'arm-game'});
      expect(
        tester
            .widget<DesktopGroupedGameKeyboardFocus>(
              find.byType(DesktopGroupedGameKeyboardFocus),
            )
            .groups
            .expand((group) => group.games)
            .map((game) => game.gameId)
            .toSet(),
        {'day-two-game', 'arm-game'},
        reason: 'Keyboard navigation must not enter a folded day.',
      );
      expect(
        find.text('1–0'),
        findsNWidgets(2),
        reason: 'Folded weighted daily scores remain visible.',
      );
      await tester.tap(find.text('Day 2'));
      await tester.pump();
      expect(mountedIds(), {'arm-game'});
      await tester.tap(find.text('Day 1'));
      await tester.pump();
      expect(mountedIds(), {'day-one-game', 'arm-game'});
      // A parent fold/reopen retains the independently folded Day 2.
      await tester.tap(find.text('Alpha, Anna').first);
      await tester.pump();
      expect(mountedIds(), isEmpty);
      await tester.tap(find.text('Alpha, Anna').first);
      await tester.pump();
      expect(mountedIds(), {'day-one-game', 'arm-game'});
      await tester.tap(find.text('Semifinals'));
      await tester.pump();
      expect(mountedIds(), isEmpty);
      await tester.tap(find.text('Semifinals'));
      await tester.pump();
      expect(mountedIds(), {'day-one-game', 'arm-game'});
      // The header is one keyboard stop; Enter and Space mirror clicking.
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      final dayFocusRing = find.ancestor(
        of: find.text('Day 1'),
        matching: find.byType(FFocusedOutline),
      );
      for (
        var stop = 0;
        stop < 24 && !tester.widget<FFocusedOutline>(dayFocusRing).focused;
        stop++
      ) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(tester.widget<FFocusedOutline>(dayFocusRing).focused, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(mountedIds(), {'arm-game'});
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(mountedIds(), {'day-one-game', 'arm-game'});
      await tester.tap(find.text('Armageddon'));
      await tester.pump();
      expect(mountedIds(), {'day-one-game'});
      await tester.tap(find.text('Armageddon'));
      await tester.pump();
      expect(mountedIds(), {'day-one-game', 'arm-game'});
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'a knockout match shorter than a row sits centered under its pairing',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final alpha = _player('Alpha, Anna');
      final beta = _player('Beta, Boris');
      GamesTourModel game(String id, PlayerCard white, PlayerCard black) =>
          GamesTourModel(
            gameId: id,
            whitePlayer: white,
            blackPlayer: black,
            whiteTimeDisplay: '05:00',
            blackTimeDisplay: '05:00',
            whiteClockCentiseconds: 30000,
            blackClockCentiseconds: 30000,
            gameStatus: GameStatus.draw,
            roundId: 'final',
            roundSlug: 'final',
            tourId: '',
          );
      final games = [game('m1', alpha, beta), game('m2', beta, alpha)];
      final round = GamesAppBarModel(
        id: 'final',
        name: 'Final',
        startsAt: DateTime.utc(2026, 11, 15, 12),
        roundStatus: RoundStatus.completed,
      );
      final grouped = GroupedGamesData(
        filteredRounds: [round],
        gamesByRound: {round.id: games},
        isKnockoutTournament: true,
        isMultiStageKnockout: false,
        isLoading: false,
        rounds: [round],
        allGames: games,
        providerGameCount: games.length,
      );
      final container = ProviderContainer(
        overrides: [
          gamesTourGroupedProvider.overrideWith((ref) => grouped),
          gamesTourScreenProvider.overrideWith(
            (ref) => _SearchFocusGamesNotifier(ref),
          ),
          boardSettingsProviderNew.overrideWith(_EvaluationBarOffNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _EngineSettingsOffNotifier.new,
          ),
          gameStreamRepositoryProvider.overrideWithValue(
            _TrackingGameStreamRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: TournamentGamesView(
                tabId: 'sparse-match-tab',
                tournamentId: 'sparse-match-tour',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final cards = [
        for (final element in find.byType(DesktopGameCard).evaluate())
          tester.getRect(find.byWidget(element.widget)),
      ];
      expect(cards, hasLength(2));
      final separator = tester.getRect(find.text('–').first);
      final cardsLeft = cards.map((rect) => rect.left).reduce(math.min);
      final cardsRight = cards.map((rect) => rect.right).reduce(math.max);
      expect((cardsLeft + cardsRight) / 2, closeTo(separator.center.dx, 1));
      expect(
        cardsLeft,
        greaterThan(tester.getRect(find.byType(RoundHeaderCard)).left + 100),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}

class _SearchFocusGamesNotifier extends GamesTourScreenProvider {
  _SearchFocusGamesNotifier(Ref ref) : super.loading(ref: ref) {
    state = AsyncData(_state());
  }

  static GamesScreenModel _state({String? query}) {
    return GamesScreenModel(
      gamesTourModels: const [],
      pinnedGamedIs: const [],
      isSearchMode: query != null,
      searchQuery: query,
    );
  }

  @override
  Future<void> searchGamesEnhanced(String query) async {
    state = AsyncData(_state(query: query));
  }

  @override
  void clearSearch() {
    state = AsyncData(_state());
  }
}

class _TrackingGameStreamRepository extends GameStreamRepository {
  int individualSubscriptions = 0;
  int batchSubscriptions = 0;
  int roundSubscriptions = 0;
  int tourSubscriptions = 0;
  int activeBatchSubscriptions = 0;
  int peakActiveBatchSubscriptions = 0;
  final List<int> requestedBatchSizes = <int>[];

  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) {
    individualSubscriptions++;
    return const Stream<LiveGameUpdate?>.empty();
  }

  @override
  Stream<Map<String, dynamic>?> subscribeToGameUpdates(String gameId) {
    individualSubscriptions++;
    return const Stream<Map<String, dynamic>?>.empty();
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) {
    batchSubscriptions++;
    requestedBatchSizes.add(gameIds.length);
    late final StreamController<Map<String, LiveGameUpdate>> controller;
    controller = StreamController<Map<String, LiveGameUpdate>>(
      onListen: () {
        activeBatchSubscriptions++;
        if (activeBatchSubscriptions > peakActiveBatchSubscriptions) {
          peakActiveBatchSubscriptions = activeBatchSubscriptions;
        }
      },
      onCancel: () {
        activeBatchSubscriptions--;
        scheduleMicrotask(controller.close);
      },
    );
    return controller.stream;
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) {
    roundSubscriptions++;
    return const Stream<Map<String, LiveGameUpdate>>.empty();
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) {
    tourSubscriptions++;
    return const Stream<Map<String, LiveGameUpdate>>.empty();
  }
}

GamesTourModel _game(int index) {
  return GamesTourModel(
    gameId: 'game-$index',
    whitePlayer: _player('White $index'),
    blackPlayer: _player('Black $index'),
    whiteTimeDisplay: '05:00',
    blackTimeDisplay: '05:00',
    whiteClockCentiseconds: 30000,
    blackClockCentiseconds: 30000,
    gameStatus: GameStatus.ongoing,
    roundId: 'round-1',
    tourId: 'tour-1',
    tourSlug: 'stress-event',
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: null,
  );
}

class _EvaluationBarOffNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _EngineSettingsOffNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings(showEngineGauge: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _NoPollingGames extends StateNotifier<AsyncValue<List<Games>>>
    implements GamesTourNotifier {
  _NoPollingGames() : super(const AsyncData([]));

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
