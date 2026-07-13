import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
