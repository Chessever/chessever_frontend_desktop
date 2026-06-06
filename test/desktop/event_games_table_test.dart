import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:dio/dio.dart';

void main() {
  testWidgets('database games hide the board and round column', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          pgn: '1. d4 d5 *',
          label: 'Database game',
          whiteName: 'White',
          blackName: 'Black',
          databaseTitle: 'My Database',
          databaseGames: [_summary(id: 'db-game-1', roundLabel: 'R9')],
          gameListSelectedId: 'db-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('DATABASE GAMES'), findsOneWidget);
    expect(find.text('BD'), findsNothing);
    expect(find.text('R9'), findsNothing);
    expect(find.text('White Player'), findsOneWidget);
    expect(find.text('Black Player'), findsOneWidget);
  });

  testWidgets(
    'opening a database row with header-only PGN keeps hydration id',
    (tester) async {
      const headerOnlyPgn = '[White "Header"]\n[Black "Only"]\n\n*';

      await tester.pumpWidget(
        _wrap(
          BoardTabGameArgs(
            gameId: 'db-game-1',
            pgn: headerOnlyPgn,
            label: 'Database game',
            whiteName: 'White',
            blackName: 'Black',
            databaseTitle: 'TWIC Database',
            databaseGames: [
              _summary(
                id: 'db-game-1',
                roundLabel: '2026',
                whitePlayer: 'Header One',
                blackPlayer: 'Only One',
                pgn: headerOnlyPgn,
              ),
              _summary(
                id: 'db-game-2',
                roundLabel: '2026',
                whitePlayer: 'Header Two',
                blackPlayer: 'Only Two',
                pgn: headerOnlyPgn,
              ),
            ],
            gameListSelectedId: 'db-game-1',
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Only Two'));
      await tester.pump();

      var container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      var args = container.read(boardTabGameArgsByTabIdProvider).values.single;
      expect(args.gameId, 'db-game-1');
      expect(args.gameListSelectedId, 'db-game-1');

      await tester.tap(find.text('Only Two'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Only Two'));
      await tester.pump(const Duration(milliseconds: 100));

      container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      args = container.read(boardTabGameArgsByTabIdProvider).values.single;
      expect(args.gameId, 'db-game-2');
      expect(args.gameListSelectedId, 'db-game-2');
      expect(args.pgn, headerOnlyPgn);
    },
  );

  testWidgets('database games rail loads the next position-games page', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();
    const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          pgn: '',
          label: 'Database game',
          whiteName: 'White',
          blackName: 'Black',
          initialFen: fen,
          databaseTitle: 'Continuation after 1.e4',
          databaseGames: [_summary(id: 'gamebase-1', roundLabel: '2025')],
          databaseGamesPagination: const BoardTabDatabaseGamesPagination(
            query: GamebasePositionGamesQuery(
              fen: fen,
              pageNumber: 0,
              pageSize: 1,
              notationPlies: 12,
            ),
            nextPageNumber: 1,
            hasMore: true,
            exactFenSearch: false,
            totalCount: 2,
          ),
          gameListSelectedId: 'gamebase-1',
        ),
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;

    expect(repository.requestedPages, [1]);
    expect(args.databaseGames.map((game) => game.id), [
      'gamebase-1',
      'gamebase-2',
    ]);
    expect(args.databaseGamesPagination!.nextPageNumber, 2);
    expect(args.databaseGamesPagination!.hasMore, isFalse);
  });

  testWidgets('Enter opens the highlighted source game from the rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'source-game-1',
          pgn: '1. e4 e5 *',
          label: 'Source game',
          whiteName: 'White One',
          blackName: 'Black One',
          routeTitle: 'Player games',
          routeGames: [
            _summary(
              id: 'source-game-1',
              roundLabel: '2026',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'source-game-2',
              roundLabel: '2026',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'source-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('White One'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'source-game-2');
    expect(args.gameListSelectedId, 'source-game-2');
    expect(args.routeGames.map((game) => game.id), [
      'source-game-1',
      'source-game-2',
    ]);
  });

  testWidgets('event games keep the board and round column', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('EVENT GAMES'), findsOneWidget);
    expect(find.text('BD'), findsOneWidget);
    expect(find.text('R5'), findsOneWidget);
  });

  testWidgets('event round header preserves Armageddon round name', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'armageddon-1',
          pgn: '1. e4 e5 *',
          label: 'Armageddon game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Norway Chess 2026',
          eventGames: [
            _summary(
              id: 'armageddon-1',
              roundLabel: 'R1',
              roundName: 'Round 1 / Armageddon',
            ),
          ],
          gameListSelectedId: 'armageddon-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Round 1 / Armageddon'), findsOneWidget);
    expect(find.text('Round 1'), findsNothing);
  });

  testWidgets('event rounds sort by descending start datetime', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-1-game',
              roundLabel: 'R1',
              startsAt: DateTime(2026, 1, 1, 10),
            ),
            _summary(
              id: 'round-3-game',
              roundLabel: 'R3',
              startsAt: DateTime(2026, 1, 3, 10),
            ),
            _summary(
              id: 'round-2-game',
              roundLabel: 'R2',
              startsAt: DateTime(2026, 1, 2, 10),
            ),
          ],
          gameListSelectedId: 'round-2-game',
        ),
      ),
    );
    await tester.pump();

    final round3Top = tester.getTopLeft(find.text('Round 3')).dy;
    final round2Top = tester.getTopLeft(find.text('Round 2')).dy;
    final round1Top = tester.getTopLeft(find.text('Round 1')).dy;

    expect(round3Top, lessThan(round2Top));
    expect(round2Top, lessThan(round1Top));
  });

  testWidgets('event round header prefers canonical round start time', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-1-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-1-game',
              roundLabel: 'R1',
              startsAt: DateTime(2026, 5, 22),
              roundStartsAt: DateTime(2026, 5, 25, 11),
            ),
          ],
          gameListSelectedId: 'round-1-game',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('25 May 2026 11:00'), findsOneWidget);
    expect(find.text('22 May 2026 00:00'), findsNothing);
  });

  testWidgets('selected top event round stays collapsed after header tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-1-game',
              roundLabel: 'R1',
              whitePlayer: 'Round One White',
              blackPlayer: 'Round One Black',
              startsAt: DateTime(2026, 1, 1, 10),
            ),
            _summary(
              id: 'round-2-game',
              roundLabel: 'R2',
              whitePlayer: 'Selected White',
              blackPlayer: 'Selected Black',
              startsAt: DateTime(2026, 1, 2, 10),
            ),
          ],
          gameListSelectedId: 'round-2-game',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('Selected White'), findsOneWidget);

    await tester.tap(find.text('Round 2'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('Selected White'), findsNothing);
    expect(find.text('Round One White'), findsOneWidget);
  });

  testWidgets('event games within a round sort by descending start datetime', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'later-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'earlier-game',
              roundLabel: 'R1',
              whitePlayer: 'Earlier White',
              blackPlayer: 'Earlier Black',
              startsAt: DateTime(2026, 1, 1, 9),
            ),
            _summary(
              id: 'later-game',
              roundLabel: 'R1',
              whitePlayer: 'Later White',
              blackPlayer: 'Later Black',
              startsAt: DateTime(2026, 1, 1, 11),
            ),
          ],
          gameListSelectedId: 'later-game',
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('Later White')).dy,
      lessThan(tester.getTopLeft(find.text('Earlier White')).dy),
    );
  });

  testWidgets('upcoming event rounds stay hidden until see more is toggled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-2-game',
              roundLabel: 'R2',
              startsAt: DateTime(2026, 1, 2, 10),
            ),
            _summary(
              id: 'round-4-game',
              roundLabel: 'R4',
              status: GameStatus.ongoing,
              hasStarted: false,
              startsAt: DateTime(2030, 1, 4, 10),
            ),
          ],
          gameListSelectedId: 'round-2-game',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('See 1 upcoming round'), findsOneWidget);
    expect(find.text('1 game scheduled'), findsOneWidget);
    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('Round 4'), findsNothing);

    await tester.tap(find.text('See 1 upcoming round'));
    await tester.pumpAndSettle();

    expect(find.text('Hide upcoming rounds'), findsOneWidget);
    expect(find.text('Round 4'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Round 4')).dy,
      lessThan(tester.getTopLeft(find.text('Round 2')).dy),
    );
  });

  testWidgets('event game rows are tappable in the fixed table rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'R5',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'event-game-2',
              roundLabel: 'R5',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Black Two'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Black Two'));
    await tester.pump(const Duration(milliseconds: 100));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'event-game-2');
    expect(args.gameListSelectedId, 'event-game-2');
    expect(args.pgn, '1. e4 e5 *');
  });

  testWidgets('selected event game gets a full-row container treatment', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    final table = tester.widget<Table>(find.byType(Table));
    final selectedDecoration = table.children[1].decoration as BoxDecoration;
    expect(selectedDecoration.color, isNotNull);
    expect(selectedDecoration.border, isNotNull);
    expect(selectedDecoration.boxShadow, isNotEmpty);
  });

  testWidgets('single click moves the only highlighted game row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White One',
          blackName: 'Black One',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'R5',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'event-game-2',
              roundLabel: 'R5',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    var table = tester.widget<Table>(find.byType(Table));
    var firstDecoration = table.children[1].decoration as BoxDecoration;
    var secondDecoration = table.children[2].decoration as BoxDecoration;
    expect(firstDecoration.color, isNot(Colors.transparent));
    expect(secondDecoration.color, Colors.transparent);

    await tester.tap(find.text('Black Two'));
    await tester.pump(const Duration(milliseconds: 350));

    table = tester.widget<Table>(find.byType(Table));
    firstDecoration = table.children[1].decoration as BoxDecoration;
    secondDecoration = table.children[2].decoration as BoxDecoration;
    expect(firstDecoration.color, Colors.transparent);
    expect(secondDecoration.color, isNot(Colors.transparent));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'event-game-1');
    expect(args.gameListSelectedId, 'event-game-1');
  });

  testWidgets('Ctrl click opens a game row in a new tab', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White One',
          blackName: 'Black One',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'R5',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'event-game-2',
              roundLabel: 'R5',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    final ctrlClick = await tester.startGesture(
      tester.getCenter(find.text('Black Two')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await ctrlClick.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump(const Duration(milliseconds: 350));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final gamesByTab = container.read(boardTabGameArgsByTabIdProvider);
    expect(
      gamesByTab.values.map((args) => args.gameId),
      contains('event-game-1'),
    );
    expect(
      gamesByTab.values.map((args) => args.gameId),
      contains('event-game-2'),
    );
    expect(gamesByTab.length, 2);
  });

  testWidgets('event games show loading shimmer while context hydrates', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          eventGamesLoading: true,
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Loading…'), findsOneWidget);
    expect(find.byType(AnimatedBuilder), findsWidgets);
  });

  testWidgets(
    'route context is the default rail when event context also exists',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          BoardTabGameArgs(
            gameId: 'route-game-1',
            pgn: '1. e4 e5 *',
            label: 'Profile game',
            whiteName: 'White',
            blackName: 'Black',
            tournamentTitle: 'Tournament context',
            eventGames: [
              _summary(
                id: 'event-game-1',
                roundLabel: 'R5',
                whitePlayer: 'Event White',
                blackPlayer: 'Event Black',
              ),
            ],
            routeTitle: 'Player games',
            routeGames: [
              _summary(
                id: 'route-game-1',
                roundLabel: 'R1',
                whitePlayer: 'Route White',
                blackPlayer: 'Route Black',
              ),
              _summary(
                id: 'route-game-2',
                roundLabel: 'R2',
                whitePlayer: 'Route Two',
                blackPlayer: 'Route Opponent',
              ),
            ],
            gameListSelectedId: 'route-game-1',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('SOURCE GAMES'), findsOneWidget);
      expect(find.text('Player games'), findsOneWidget);
      expect(find.text('Source'), findsOneWidget);
      expect(find.text('Event'), findsOneWidget);
      expect(find.text('Route Two'), findsOneWidget);
      expect(find.text('Event White'), findsNothing);

      await tester.tap(find.text('Event'));
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.text('EVENT GAMES'), findsOneWidget);
      expect(find.text('Tournament context'), findsOneWidget);
      expect(find.text('Event White'), findsOneWidget);
      expect(find.text('Route Two'), findsNothing);
    },
  );

  testWidgets('opening a route row preserves the source game list', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'route-game-1',
          pgn: '1. e4 e5 *',
          label: 'Profile game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Tournament context',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          routeTitle: 'Player games',
          routeGames: [
            _summary(
              id: 'route-game-1',
              roundLabel: 'R1',
              whitePlayer: 'Route White',
              blackPlayer: 'Route Black',
            ),
            _summary(
              id: 'route-game-2',
              roundLabel: 'R2',
              whitePlayer: 'Route Two',
              blackPlayer: 'Route Opponent',
            ),
          ],
          gameListSelectedId: 'route-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Route Two'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Route Two'));
    await tester.pump(const Duration(milliseconds: 100));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'route-game-2');
    expect(args.gameListSelectedId, 'route-game-2');
    expect(args.routeTitle, 'Player games');
    expect(args.routeGames.map((game) => game.id), [
      'route-game-1',
      'route-game-2',
    ]);
  });

  testWidgets('tabs without local context ignore stale tournament state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const BoardTabGameArgs(
          pgn: '1. c4 e5 *',
          label: 'Scratch analysis',
          whiteName: 'White',
          blackName: 'Black',
        ),
        legacy: TournamentGamesState(
          tournamentTitle: 'Wrong Event',
          games: [_summary(id: 'stale-game-1', roundLabel: 'R1')],
          activeGameId: 'stale-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('EVENT GAMES'), findsNothing);
    expect(find.text('Wrong Event'), findsNothing);
    expect(find.text('White Player'), findsNothing);
  });
}

Widget _wrap(
  BoardTabGameArgs args, {
  TournamentGamesState? legacy,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      ...overrides,
      boardTabGameArgsByTabIdProvider.overrideWith(
        (ref) => {'tournaments-default': args},
      ),
      if (legacy != null)
        tournamentGamesProvider.overrideWith((ref) {
          final notifier = TournamentGamesNotifier();
          notifier.setLoaded(
            tournamentTitle: legacy.tournamentTitle,
            games: legacy.games,
          );
          if (legacy.activeGameId != null) {
            notifier.markActive(legacy.activeGameId!);
          }
          return notifier;
        }),
      gameUpdatesStreamProvider.overrideWith(
        (ref, gameId) => const Stream<Map<String, dynamic>?>.empty(),
      ),
      gameUpdatesBatchStreamProvider.overrideWith(
        (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: EventGamesTable.width,
          child: EventGamesTable(tabId: 'tournaments-default'),
        ),
      ),
    ),
  );
}

class _FakeGamebaseRepository extends GamebaseRepository {
  _FakeGamebaseRepository() : super(Dio(), baseUrl: 'http://localhost');

  final List<int> requestedPages = <int>[];

  @override
  Future<GamebaseSearchQueryResponse> getPositionGames({
    required String fen,
    List<String> moves = const [],
    String? uci,
    TimeControl? timeControl,
    String? playerId,
    String? color,
    String? result,
    int? minRating,
    int? maxRating,
    int? yearFrom,
    int? yearTo,
    GamebaseSortField? sortBy,
    GamebaseSortDirection? sortDirection,
    bool? isOnline,
    int pageNumber = 0,
    int pageSize = 20,
    int notationPlies = 0,
  }) async {
    requestedPages.add(pageNumber);
    return GamebaseSearchQueryResponse(
      status: 'success',
      data: const [
        {
          'id': 'gamebase-2',
          'white': 'Caruana',
          'black': 'Giri',
          'whiteFed': 'USA',
          'blackFed': 'NED',
          'whiteTitle': 'GM',
          'blackTitle': 'GM',
          'whiteElo': 2800,
          'blackElo': 2760,
          'result': '1/2-1/2',
          'date': '2024-01-01',
          'event': 'Wijk aan Zee',
          'opening': 'Open Game',
          'eco': 'C20',
        },
      ],
      metadata: GamebasePaginationMetadata(
        pageNumber: pageNumber,
        pageSize: pageSize,
        totalCount: 2,
        hasMoreValue: false,
      ),
    );
  }
}

TournamentGameSummary _summary({
  required String id,
  required String roundLabel,
  String whitePlayer = 'White Player',
  String blackPlayer = 'Black Player',
  String pgn = '1. e4 e5 *',
  GameStatus status = GameStatus.draw,
  bool hasStarted = true,
  DateTime? startsAt,
  DateTime? roundStartsAt,
  DateTime? lastMoveTime,
  String roundName = '',
}) {
  return TournamentGameSummary(
    id: id,
    name: '$whitePlayer vs $blackPlayer',
    whitePlayer: whitePlayer,
    blackPlayer: blackPlayer,
    hasPgn: true,
    pgn: pgn,
    roundLabel: roundLabel,
    roundName: roundName,
    status: status,
    lastMoveTime: lastMoveTime,
    startsAt: startsAt,
    roundStartsAt: roundStartsAt,
    hasStarted: hasStarted,
  );
}
