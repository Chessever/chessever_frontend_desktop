import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _canonicalGameId = 'fe6351a5-6354-4c16-b7f6-9124e5d9a9ef';
const _fullPgn = '''
[Event "Smart Event"]
[Site "ChessEver"]
[Date "2026.07.13"]
[White "White"]
[Black "Black"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 *
''';
const _shortPgn = '''
[Event "Smart Event"]
[Site "ChessEver"]
[Date "2026.07.13"]
[White "White"]
[Black "Black"]
[Result "*"]

1. e4 *
''';
const _headerOnlyPgn = '''
[Event "Smart Event"]
[Site "ChessEver"]
[Date "2026.07.13"]
[White "White"]
[Black "Black"]
[Result "*"]

*
''';

GamesTourModel _game({
  String gameId = _canonicalGameId,
  GameSource source = GameSource.supabase,
  String? pgn,
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
  );
}

void main() {
  group('desktop Gamebase Smart Event sharing', () {
    test('uses the Supabase deep link for a canonical Gamebase UUID', () {
      final supabaseUrl = buildDesktopGameShareUrl(game: _game());
      final gamebaseUrl = buildDesktopGameShareUrl(
        game: _game(source: GameSource.gamebase),
      );

      expect(gamebaseUrl, supabaseUrl);
      expect(
        gamebaseUrl,
        'https://chessever.com/games/$_canonicalGameId?tour=smart-event&round=A00',
      );
    });

    test('keeps local, short-ID, and non-Gamebase UUID rows unshareable', () {
      expect(
        buildDesktopGameShareUrl(
          game: _game(gameId: 'gamebase-local-1', source: GameSource.gamebase),
        ),
        isNull,
      );
      expect(
        buildDesktopGameShareUrl(
          game: _game(gameId: 'abcdefgh', source: GameSource.gamebase),
        ),
        isNull,
      );
      expect(
        buildDesktopGameShareUrl(game: _game(source: GameSource.twic)),
        isNull,
      );
    });

    test(
      'hydrates a canonical Gamebase row from Supabase before export',
      () async {
        var supabaseCalls = 0;
        var gamebaseCalls = 0;

        final resolved = await resolveDesktopGameSharePgn(
          game: _game(source: GameSource.gamebase, pgn: _shortPgn),
          fetchSupabasePgn: (gameId) async {
            supabaseCalls++;
            expect(gameId, _canonicalGameId);
            return _fullPgn;
          },
          fetchGamebasePgn: (_) async {
            gamebaseCalls++;
            return _shortPgn;
          },
        );

        expect(resolved, contains('2. Nf3 Nc6'));
        expect(supabaseCalls, 1);
        expect(gamebaseCalls, 0);
      },
    );

    test('keeps a local Gamebase PGN on the Gamebase fallback path', () async {
      var supabaseCalls = 0;
      var gamebaseCalls = 0;

      final resolved = await resolveDesktopGameSharePgn(
        game: _game(
          gameId: 'gamebase-local-1',
          source: GameSource.gamebase,
          pgn: _headerOnlyPgn,
        ),
        fetchSupabasePgn: (_) async {
          supabaseCalls++;
          return _fullPgn;
        },
        fetchGamebasePgn: (gameId) async {
          gamebaseCalls++;
          expect(gameId, 'gamebase-local-1');
          return _fullPgn;
        },
      );

      expect(resolved, contains('2. Nf3 Nc6'));
      expect(supabaseCalls, 0);
      expect(gamebaseCalls, 1);
    });
  });
}
