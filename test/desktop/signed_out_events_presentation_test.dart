import 'package:chessever/desktop/widgets/desktop_spinner.dart';
import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/state/signed_out_events_presentation.dart';
import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/state/event_artwork_provider.dart';
import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/desktop/widgets/desktop_collection_cards.dart';
import 'package:chessever/desktop/widgets/desktop_event_countdown.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_for_you_strip_layout.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/widgets/event_card/event_next_round_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _NeutralBoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: false);
    state = const AsyncData(settings);
    return settings;
  }
}

// Deliberately small test-only input, never a production fallback dataset.
const _event = GroupEventCardModel(
  id: 'test-event',
  title: 'Event A',
  dates: '',
  maxAvgElo: 2500,
  timeUntilStart: '',
  tourEventCategory: TourEventCategory.upcoming,
  timeControl: 'Classical',
  endDate: null,
  startDate: null,
);

GamesTourModel _game(String id) {
  final player = PlayerCard(
    name: 'Player',
    federation: '',
    title: '',
    rating: 2500,
    countryCode: '',
    fideId: null,
    team: null,
  );
  return GamesTourModel(
    gameId: id,
    source: GameSource.supabase,
    whitePlayer: player,
    blackPlayer: player,
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.draw,
    roundId: 'test-round',
    tourId: 'test-tour',
    // The test's actual e4/e5/Nf3/Nc6 position, not a starting-board stand-in.
    fen: 'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3',
  );
}

// Sources authored for the analyze-only handoff; not executed in this task.
void main() {
  for (final mode in GamesListViewMode.values) {
    testWidgets('supplied $mode uses the actual event and game widget graph', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2000, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final forbiddenReads = <String>[];
      Never forbidden(String name) {
        forbiddenReads.add(name);
        throw StateError('$name must not start');
      }

      final games = [_game('test-board-b'), _game('test-board-a')];
      final capturedAt = DateTime.utc(2026, 11, 9, 12);
      final data = SignedOutEventsPresentationData(
        capturedAt: capturedAt,
        viewMode: mode,
        forYouEvents: const AsyncData([_event]),
        snapshots: {
          _event.id: ForYouEventGamesSnapshot(
            eventId: _event.id,
            tourId: 'test-tour',
            visibleGames: games,
            pinnedIds: const [],
          ),
        },
        nextRounds: {
          _event.id: NextRoundInfo(
            name: 'Round 2',
            startsAt: capturedAt.add(const Duration(minutes: 30)),
          ),
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(_NeutralBoardSettings.new),
            engineSettingsProviderNew.overrideWith(() => forbidden('engine')),
            forYouEventsProvider.overrideWith(
              (ref) => forbidden('ForYouNotifier'),
            ),
            groupEventScreenProvider.overrideWith((ref) => forbidden('group')),
            tournamentLiveEventPrefetchProvider.overrideWith(
              (ref) => forbidden('prefetch'),
            ),
            favoritePlayersProviderNew.overrideWith(
              () => forbidden('favoritePlayers'),
            ),
            favoriteEventsProvider.overrideWith(
              () => forbidden('favoriteEvents'),
            ),
            eventNextRoundProvider.overrideWith(
              (ref, id) => forbidden('nextRound'),
            ),
            eventArtworkProvider.overrideWith(
              (ref, id) => forbidden('artwork'),
            ),
            botvinnikEnabledProvider.overrideWith(() => forbidden('Botvinnik')),
            effectiveCountryProvider.overrideWith(
              (ref) => forbidden('profileCountry'),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                ResponsiveHelper.init(context);
                return Scaffold(
                  body: TournamentsPane(
                    tabId: 'signed-out-events',
                    readOnlyPresentation: true,
                    presentationData: data,
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final cards =
          tester
              .widgetList<LiveDesktopGameCard>(find.byType(LiveDesktopGameCard))
              .toList();
      expect(cards.map((card) => card.game.gameId), [
        'test-board-b',
        'test-board-a',
      ]);
      expect(cards.every((card) => card.readOnlyPresentation), isTrue);
      expect(cards.every((card) => !card.streamingEnabled), isTrue);
      expect(find.byType(DesktopGameCard), findsNWidgets(2));
      expect(
        tester
            .widgetList<DesktopGameCard>(find.byType(DesktopGameCard))
            .every(
              (card) => card.visualPreviewOnly && !card.allowStockfishFallback,
            ),
        isTrue,
      );
      expect(find.byType(DesktopForYouGamesPreview), findsOneWidget);
      expect(find.byType(DesktopCollectionCards), findsOneWidget);
      final collections = tester.widget<DesktopCollectionCards>(
        find.byType(DesktopCollectionCards),
      );
      collections.onFavoritesTap();
      collections.onCountrymenTap();
      collections.onLikesTap();
      expect(find.byType(DesktopEventCountdownLine), findsOneWidget);
      expect(find.text('Event A'), findsOneWidget);
      final shortcuts = [
        'Favorites',
        'Countrymen',
        'Collections',
        'Likes',
        'Miniatures',
      ];
      final positions =
          shortcuts
              .map((title) => tester.getTopLeft(find.text(title)).dx)
              .toList();
      expect(positions, orderedEquals([...positions]..sort()));
      final label = desktopRoundStartLabel(
        roundName: 'Round 2',
        startsAt: data.nextRounds[_event.id]!.startsAt,
        now: capturedAt,
      );
      expect(find.text(label), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(label), findsOneWidget); // Frozen captured clock.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(forbiddenReads, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(
        forbiddenReads,
        isEmpty,
      ); // No delayed bookmark/account write work.
      expect(tester.takeException(), isNull);
    });
  }

  for (final category in [
    GroupEventCategory.forYou,
    GroupEventCategory.current,
    GroupEventCategory.past,
  ]) {
    testWidgets(
      'inert $category does not construct production feed controllers',
      (tester) async {
        tester.view.resetPhysicalSize();
        tester.view.physicalSize = const Size(1800, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = SignedOutEventsPresentationData(
          capturedAt: DateTime.utc(2026, 11, 9),
          selectedCategory: category,
          forYouEvents: const AsyncValue.loading(),
          currentEvents: const AsyncValue.loading(),
          pastEvents: const AsyncValue.loading(),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              forYouEventsProvider.overrideWith(
                (ref) =>
                    throw StateError('ForYouNotifier must not be constructed'),
              ),
              groupEventScreenProvider.overrideWith(
                (ref) =>
                    throw StateError(
                      'group controller must not be constructed',
                    ),
              ),
              tournamentLiveEventPrefetchProvider.overrideWith(
                (ref) => throw StateError('live prefetch must not start'),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: TournamentsPane(
                  tabId: 'signed-out-events',
                  readOnlyPresentation: true,
                  presentationData: data,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('For You'), findsOneWidget);
        expect(find.byType(LiveDesktopGameCard), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final category in [
    GroupEventCategory.current,
    GroupEventCategory.past,
  ]) {
    testWidgets(
      'resolved $category retains actual compact tiles without keyboard ownership',
      (tester) async {
        tester.view.physicalSize = const Size(2000, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final authFocus = FocusNode();
        addTearDown(authFocus.dispose);
        final data = SignedOutEventsPresentationData(
          capturedAt: DateTime.utc(2026, 11, 9),
          selectedCategory: category,
          forYouEvents: const AsyncValue.loading(),
          currentEvents: const AsyncData([_event]),
          pastEvents: const AsyncData([_event]),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  ResponsiveHelper.init(context);
                  return Scaffold(
                    body: Column(
                      children: [
                        TextField(focusNode: authFocus),
                        Expanded(
                          child: TournamentsPane(
                            tabId: 'signed-out-events',
                            readOnlyPresentation: true,
                            presentationData: data,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
        authFocus.requestFocus();
        await tester.pump();
        expect(find.byType(GridView), findsOneWidget);
        expect(find.text('Event A'), findsOneWidget);
        expect(
          find.text('Completed'),
          findsNothing,
        ); // Past hides redundant status badges.
        expect(
          find.text('Upcoming'),
          category == GroupEventCategory.past ? findsNothing : findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(authFocus.hasPrimaryFocus, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('missing snapshots remain loading, never an invented empty dataset', () {
    final data = SignedOutEventsPresentationData(
      capturedAt: DateTime.utc(2026, 11, 9),
      forYouEvents: const AsyncValue<List<GroupEventCardModel>>.loading(),
    );
    expect(data.selectedCategory, GroupEventCategory.forYou);
    expect(data.snapshotFor('not-supplied').isLoading, isTrue);
    expect(data.viewMode.index, 1);
  });

  testWidgets(
    'missing supplied data keeps honest loading and persistent discovery shortcuts',
    (tester) async {
      tester.view.physicalSize = const Size(1800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TournamentsPane(
                tabId: 'signed-out-events',
                readOnlyPresentation: true,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(DesktopCollectionCards), findsOneWidget);
      expect(find.byType(DesktopSpinner), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
