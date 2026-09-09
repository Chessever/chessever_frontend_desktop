import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/chessboard/utils/game_share_utils.dart';
import 'package:chessever/screens/chessboard/view_model/chess_board_state_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _canonicalGameId = 'fe6351a5-6354-4c16-b7f6-9124e5d9a9ef';
const _fullPgn = '''
[Event "Test Event"]
[Site "ChessEver"]
[Date "2026.03.25"]
[White "White"]
[Black "Black"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 *
''';
const _headerOnlyPgn = '''
[Event "Test Event"]
[Site "ChessEver"]
[Date "2026.03.25"]
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
      fideId: null,
    ),
    blackPlayer: PlayerCard(
      name: 'Black',
      federation: '',
      title: '',
      rating: 0,
      countryCode: '',
      team: null,
      fideId: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.ongoing,
    roundId: 'round',
    roundSlug: 'A00',
    tourId: 'tour',
    tourSlug: 'tour-slug',
    pgn: pgn,
  );
}

SavedAnalysisData _savedAnalysisData({String? sourceGameId}) {
  return SavedAnalysisData(
    analysisId: 'analysis-1',
    sourceGameId: sourceGameId,
    chessGame: ChessGame.fromPgn('saved', _fullPgn),
    variationComments: const <String, String>{},
    isBoardFlipped: false,
    lastViewedPosition: 0,
  );
}

void main() {
  group('buildGameShareUrl', () {
    test('returns an encoded deep link for namespaced canonical games', () {
      final url = buildGameShareUrl(
        game: _game(gameId: 'chess.com:14987654321'),
      );

      expect(
        url,
        'https://chessever.com/games/chess.com%3A14987654321?tour=tour-slug&round=A00',
      );
    });

    test('preserves multi-part canonical IDs as one encoded path segment', () {
      final url = buildGameShareUrl(
        game: _game(gameId: 'chess-results:event:round:board-7'),
      );

      expect(
        url,
        'https://chessever.com/games/chess-results%3Aevent%3Around%3Aboard-7?tour=tour-slug&round=A00',
      );
    });

    test('returns a deep link for canonical Supabase games', () {
      final url = buildGameShareUrl(game: _game());

      expect(
        url,
        'https://chessever.com/games/$_canonicalGameId?tour=tour-slug&round=A00',
      );
    });

    test('returns a deep link for ChessEver Direct fallback game ids', () {
      // `<8-char round id>-<base36 hash>` minted by the broadcasting backend
      // for self-streamed boards without a stable external id.
      final url = buildGameShareUrl(
        game: _game(gameId: 'AbCd1234-1x2y3z'),
      );

      expect(
        url,
        'https://chessever.com/games/AbCd1234-1x2y3z?tour=tour-slug&round=A00',
      );
    });

    test('returns a deep link for saved analyses of ChessEver Direct games', () {
      final url = buildGameShareUrl(
        game: _game(
          gameId: 'saved_analysis_1',
          source: GameSource.savedAnalysis,
        ),
        savedAnalysisData: _savedAnalysisData(sourceGameId: 'AbCd1234-1x2y3z'),
      );

      expect(
        url,
        'https://chessever.com/games/AbCd1234-1x2y3z?tour=tour-slug&round=A00',
      );
    });

    test('returns a deep link for saved analyses with canonical source IDs', () {
      final url = buildGameShareUrl(
        game: _game(
          gameId: 'saved_analysis_1',
          source: GameSource.savedAnalysis,
        ),
        savedAnalysisData: _savedAnalysisData(sourceGameId: _canonicalGameId),
      );

      expect(
        url,
        'https://chessever.com/games/$_canonicalGameId?tour=tour-slug&round=A00',
      );
    });

    test(
      'returns null for non-canonical sources and unresolved saved analyses',
      () {
        expect(
          buildGameShareUrl(
            game: _game(gameId: 'gamebase-1', source: GameSource.gamebase),
          ),
          isNull,
        );
        expect(
          buildGameShareUrl(
            game: _game(gameId: 'twic-1', source: GameSource.twic),
          ),
          isNull,
        );
        expect(
          buildGameShareUrl(
            game: _game(
              gameId: 'explorer_123',
              source: GameSource.openingExplorer,
            ),
          ),
          isNull,
        );
        expect(
          buildGameShareUrl(
            game: _game(gameId: 'editor_123', source: GameSource.boardEditor),
          ),
          isNull,
        );
        expect(
          buildGameShareUrl(
            game: _game(gameId: 'local_123', source: GameSource.localAnalysis),
          ),
          isNull,
        );
        // `gamebase-1` would now match the ChessEver Direct id shape
        // (`<8 alnum>-<alnum>`), so the garbage sentinel uses an underscore.
        expect(
          buildGameShareUrl(
            game: _game(
              gameId: 'saved_analysis_1',
              source: GameSource.savedAnalysis,
            ),
            savedAnalysisData: _savedAnalysisData(sourceGameId: 'gamebase_1'),
          ),
          isNull,
        );
      },
    );
  });

  group('resolveGameSharePgn', () {
    test('prefers the parsed analysis game and skips remote fetches', () async {
      var supabaseCalls = 0;
      var gamebaseCalls = 0;

      final resolved = await resolveGameSharePgn(
        game: _game(pgn: _headerOnlyPgn),
        analysisGame: ChessGame.fromPgn('analysis', _fullPgn),
        savedAnalysisData: null,
        fetchSupabasePgn: (_) async {
          supabaseCalls++;
          return _fullPgn;
        },
        fetchGamebasePgn: (_) async {
          gamebaseCalls++;
          return _fullPgn;
        },
      );

      expect(resolved, contains('1. e4 e5'));
      expect(supabaseCalls, 0);
      expect(gamebaseCalls, 0);
    });

    test(
      'keeps local widget PGN for early share when it already has moves',
      () async {
        final resolved = await resolveGameSharePgn(
          game: _game(
            gameId: 'explorer_1',
            source: GameSource.openingExplorer,
            pgn: _fullPgn,
          ),
          analysisGame: null,
          savedAnalysisData: null,
        );

        expect(resolved, contains('1. e4 e5'));
      },
    );

    test('upgrades a header-only canonical PGN via Supabase fetch', () async {
      final resolved = await resolveGameSharePgn(
        game: _game(pgn: _headerOnlyPgn),
        analysisGame: null,
        savedAnalysisData: null,
        fetchSupabasePgn: (_) async => _fullPgn,
      );

      expect(resolved, contains('1. e4 e5'));
    });

    test(
      'falls back to saved analysis PGN before header-only fallback',
      () async {
        final resolved = await resolveGameSharePgn(
          game: _game(
            gameId: 'saved_analysis_1',
            source: GameSource.savedAnalysis,
            pgn: _headerOnlyPgn,
          ),
          analysisGame: null,
          savedAnalysisData: _savedAnalysisData(sourceGameId: _canonicalGameId),
        );

        expect(resolved, contains('1. e4 e5'));
      },
    );

    test('upgrades a header-only Gamebase PGN via Gamebase fetch', () async {
      final resolved = await resolveGameSharePgn(
        game: _game(
          gameId: 'gamebase-1',
          source: GameSource.gamebase,
          pgn: _headerOnlyPgn,
        ),
        analysisGame: null,
        savedAnalysisData: null,
        fetchGamebasePgn: (_) async => _fullPgn,
      );

      expect(resolved, contains('1. e4 e5'));
    });
  });

  group('buildGameShareSnapshot', () {
    test('parses the PGN when the board state is still loading', () {
      final game = _game(
        gameId: 'explorer_1',
        source: GameSource.openingExplorer,
        pgn: _fullPgn,
      );
      final state = ChessBoardStateNew(
        game: game,
        pgnData: null,
        isLoadingMoves: true,
      );

      final snapshot = buildGameShareSnapshot(
        game: game,
        pgn: _fullPgn,
        state: state,
      );

      expect(snapshot.moveSans, isNotEmpty);
      expect(snapshot.currentMoveIndex, snapshot.moveSans.length - 1);
      expect(snapshot.positionFen, isNotEmpty);
    });
  });
}
