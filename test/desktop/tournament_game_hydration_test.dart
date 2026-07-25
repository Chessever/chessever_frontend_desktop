import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _canonicalGameId = 'fe6351a5-6354-4c16-b7f6-9124e5d9a9ef';
const _headerOnlyPgn = '''
[Event "Smart Event"]
[Site "ChessEver"]
[Date "2026.07.13"]
[White "White"]
[Black "Black"]
[Result "*"]

*
''';
const _fullPgn = '''
[Event "Smart Event"]
[Site "ChessEver"]
[Date "2026.07.13"]
[White "White"]
[Black "Black"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 *
''';

GamesTourModel _game({
  String gameId = _canonicalGameId,
  GameSource source = GameSource.supabase,
  String? pgn,
  DateTime? lastMoveTime,
  int? boardNumber,
}) {
  return GamesTourModel(
    gameId: gameId,
    source: source,
    whitePlayer: PlayerCard(
      name: 'White',
      federation: '',
      title: '',
      rating: 0,
      countryCode: '',
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: 'Black',
      federation: '',
      title: '',
      rating: 0,
      countryCode: '',
      team: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.ongoing,
    roundId: 'round',
    roundSlug: 'A00',
    tourId: 'tour',
    tourSlug: 'smart-event',
    pgn: pgn,
    lastMoveTime: lastMoveTime,
    boardNr: boardNumber,
  );
}

void main() {
  group('tournament board game hydration', () {
    test(
      'hydrates a canonical Gamebase Smart Event row before board open',
      () async {
        var fetchCalls = 0;
        final local = _game(
          source: GameSource.gamebase,
          pgn: _headerOnlyPgn,
          lastMoveTime: DateTime.utc(2026, 7, 13, 12),
        );
        final canonical = _game(
          pgn: _fullPgn,
          lastMoveTime: DateTime.utc(2026, 7, 13, 12, 1),
        );

        final hydrated = await hydrateTournamentGameForBoardOpen(
          game: local,
          fetchCanonicalGame: (gameId) async {
            fetchCalls++;
            expect(gameId, _canonicalGameId);
            return canonical;
          },
        );

        expect(fetchCalls, 1);
        expect(hydrated.source, GameSource.supabase);
        expect(hydrated.pgn, contains('2. Nf3 Nc6'));
      },
    );

    test('does not fetch a local Gamebase row before board open', () async {
      var fetchCalls = 0;
      final local = _game(
        gameId: 'gamebase-local-1',
        source: GameSource.gamebase,
        pgn: _headerOnlyPgn,
      );

      final hydrated = await hydrateTournamentGameForBoardOpen(
        game: local,
        fetchCanonicalGame: (_) async {
          fetchCalls++;
          return _game(pgn: _fullPgn);
        },
      );

      expect(fetchCalls, 0);
      expect(hydrated.source, GameSource.gamebase);
      expect(hydrated.pgn, _headerOnlyPgn);
    });

    testWidgets('large events seed a bounded lazy Board rail', (tester) async {
      final games = <GamesTourModel>[
        for (var index = 0; index < 1092; index++)
          _game(gameId: 'game-$index', boardNumber: index + 1, pgn: _fullPgn),
      ];
      final selected = games[546];
      BoardTabGameArgs? args;

      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, child) {
              args = buildTournamentBoardTabArgs(
                selected,
                'Huge event',
                eventGames: games,
                viewSource: ChessboardView.forYou,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(args, isNotNull);
      expect(args!.eventGamesKey?.tourId, 'tour');
      expect(args!.eventGamesKey?.selectedGameId, selected.gameId);
      expect(args!.eventGames, hasLength(61));
      expect(
        args!.eventGames.any((game) => game.id == selected.gameId),
        isTrue,
      );
    });

    testWidgets(
      'large Favorites feeds keep a selected window plus continuation',
      (tester) async {
        final games = <GamesTourModel>[
          for (var index = 0; index < 1092; index++)
            _game(gameId: 'favorite-$index', boardNumber: index + 1),
        ];
        final selected = games[546];
        BoardTabGameArgs? args;

        await tester.pumpWidget(
          ProviderScope(
            child: Consumer(
              builder: (context, ref, child) {
                args = buildTournamentBoardTabArgs(
                  selected,
                  'Favorites',
                  eventGames: games,
                  eventGamesContinuation:
                      const BoardTabGamesContinuation.favorites(),
                  viewSource: ChessboardView.favScorecard,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect(args, isNotNull);
        expect(args!.eventGamesKey, isNull);
        expect(
          args!.eventGamesContinuation?.kind,
          BoardTabGamesContinuationKind.favorites,
        );
        expect(args!.eventGames, hasLength(61));
        expect(
          args!.eventGames.any((game) => game.id == selected.gameId),
          isTrue,
        );
      },
    );

    testWidgets(
      'player scorecard Board rails remain exact and never widen to the event',
      (tester) async {
        final playerGames = <GamesTourModel>[
          for (var index = 0; index < 12; index++)
            _game(
              gameId: 'player-game-$index',
              boardNumber: index + 1,
              pgn: _fullPgn,
            ),
        ];
        BoardTabGameArgs? args;

        await tester.pumpWidget(
          ProviderScope(
            child: Consumer(
              builder: (context, ref, child) {
                args = buildTournamentBoardTabArgs(
                  playerGames[5],
                  'Player scorecard',
                  eventGames: playerGames,
                  viewSource: ChessboardView.tour,
                  includeServerEventRail: false,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect(args, isNotNull);
        expect(args!.eventGamesKey, isNull);
        expect(args!.viewSource, ChessboardView.tour);
        expect(
          args!.eventGames.map((game) => game.id),
          playerGames.map((game) => game.gameId),
        );
      },
    );

    test('Board args can explicitly clear a stale event continuation key', () {
      const args = BoardTabGameArgs(
        pgn: '',
        label: '',
        whiteName: '',
        blackName: '',
        eventGamesKey: BoardTabEventGamesKey(tourId: 'old-tour'),
      );

      expect(args.copyWith(clearEventGamesKey: true).eventGamesKey, isNull);
    });
  });
}
