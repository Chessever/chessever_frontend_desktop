import 'package:chessever/desktop/utils/desktop_smart_game_sections.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

Games _buildGame({
  required String id,
  required int whiteRating,
  required int blackRating,
  String? pgn,
}) {
  return Games(
    id: id,
    roundId: 'round1',
    roundSlug: 'round1',
    tourId: 'tour1',
    tourSlug: 'tour1',
    status: '*',
    players: [
      Player(
        name: 'White',
        fideId: 1,
        title: 'GM',
        fed: 'USA',
        rating: whiteRating,
        clock: 0,
        team: '',
      ),
      Player(
        name: 'Black',
        fideId: 2,
        title: 'GM',
        fed: 'IND',
        rating: blackRating,
        clock: 0,
        team: '',
      ),
    ],
    pgn: pgn,
  );
}

void main() {
  group('desktop smart games GM average rating', () {
    test('uses structured player ratings when PGN rating tags are missing', () {
      final game = _buildGame(
        id: 'g1',
        whiteRating: 2520,
        blackRating: 2510,
        pgn: '[Event "Live"]\n\n1. e4 e5',
      );

      expect(gameStructuredAverageRating(game), 2515);
      expect(gameStructuredAverageRating(game) >= 2500, isTrue);
    });

    test('requires both player ratings for GM qualification', () {
      final game = _buildGame(
        id: 'g2',
        whiteRating: 2600,
        blackRating: 0,
        pgn: '[WhiteElo "2600"]\n\n1. d4 d5',
      );

      expect(gameStructuredAverageRating(game), 0);
      expect(gameStructuredAverageRating(game) >= 2500, isFalse);
    });
  });

  group('desktop smart games live filtering', () {
    test('recognizes backend ongoing status literals as live', () {
      expect(GameStatus.fromString('*'), GameStatus.ongoing);
      expect(GameStatus.fromString('ongoing'), GameStatus.ongoing);
      expect(GameStatus.fromString('live'), GameStatus.ongoing);
      expect(GameStatus.fromString('LIVE'), GameStatus.ongoing);
    });

    test('keeps only effectively ongoing games in the Live collection', () {
      final live = _tourGame(
        id: 'live',
        status: GameStatus.ongoing,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        lastMove: 'e2e4',
        whiteClockSeconds: 170,
        blackClockSeconds: 180,
      );
      final staleFinished = _tourGame(
        id: 'stale',
        status: GameStatus.ongoing,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        lastMove: 'e2e4',
        whiteClockSeconds: 0,
        blackClockSeconds: 180,
      );
      final missingClock = _tourGame(
        id: 'missing-clock',
        status: GameStatus.ongoing,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        lastMove: 'e2e4',
        whiteClockSeconds: 170,
        blackClockSeconds: null,
      );
      final finished = _tourGame(id: 'finished', status: GameStatus.whiteWins);
      final unstarted = _tourGame(
        id: 'unstarted',
        status: GameStatus.ongoing,
        fen: null,
        lastMove: null,
        whiteClockSeconds: 1800,
        blackClockSeconds: 1800,
      );

      expect(isPremiumLiveGame(live), isTrue);
      expect(isPremiumLiveGame(staleFinished), isFalse);
      expect(isPremiumLiveGame(missingClock), isFalse);
      expect(isPremiumLiveGame(finished), isFalse);
      expect(isPremiumLiveGame(unstarted), isFalse);
    });
  });

  group('desktop smart event sections', () {
    test(
      'groups by event day and orders live sections before stronger events',
      () {
        final now = DateTime(2026, 6, 22, 12);
        final sections = buildDesktopSmartGameSections(
          [
            _tourGame(
              id: 'beta-1',
              status: GameStatus.whiteWins,
              tourId: 'beta',
              tourSlug: 'stronger-event',
              gameDay: DateTime(2026, 6, 22),
              avgElo: 2820,
              boardNr: 1,
            ),
            _tourGame(
              id: 'alpha-2',
              status: GameStatus.ongoing,
              tourId: 'alpha',
              tourSlug: 'alpha-event',
              gameDay: DateTime(2026, 6, 22),
              avgElo: 2700,
              boardNr: 2,
            ),
            _tourGame(
              id: 'alpha-1',
              status: GameStatus.ongoing,
              tourId: 'alpha',
              tourSlug: 'alpha-event',
              gameDay: DateTime(2026, 6, 22),
              avgElo: 2700,
              boardNr: 1,
            ),
            _tourGame(
              id: 'future',
              status: GameStatus.ongoing,
              tourId: 'future',
              tourSlug: 'future-event',
              gameDay: DateTime(2026, 6, 23),
              avgElo: 2900,
            ),
          ],
          type: PremiumGamesType.gm,
          now: now,
        );

        expect(sections.map((section) => section.title), [
          'Alpha Event',
          'Stronger Event',
        ]);
        expect(sections.first.liveCount, 2);
        expect(sections.first.dateLabel, 'Today');
        expect(sections.first.games.map((game) => game.gameId), [
          'alpha-1',
          'alpha-2',
        ]);
      },
    );

    test('keeps separate expandable sections per classical event day', () {
      final now = DateTime(2026, 6, 22, 12);
      final sections = buildDesktopSmartGameSections(
        [
          _tourGame(
            id: 'today',
            status: GameStatus.draw,
            tourId: 'classic',
            tourSlug: 'norway-chess',
            gameDay: DateTime(2026, 6, 22),
            timeControl: 'standard',
          ),
          _tourGame(
            id: 'yesterday',
            status: GameStatus.draw,
            tourId: 'classic',
            tourSlug: 'norway-chess',
            gameDay: DateTime(2026, 6, 21),
            timeControl: 'standard',
          ),
        ],
        type: PremiumGamesType.classical,
        now: now,
      );

      expect(sections.length, 2);
      expect(sections.map((section) => section.dateLabel), [
        'Today',
        'Yesterday',
      ]);
      expect(sections.map((section) => section.title).toSet(), {
        'Norway Chess',
      });
      expect(sections.first.timeControlLabel, 'Classical');
    });

    test('prefers Supabase broadcast event names over tour slugs', () {
      final sections = buildDesktopSmartGameSections(
        [
          _tourGame(
            id: 'pool-a',
            status: GameStatus.ongoing,
            tourId: 'pool-a',
            eventName: 'FIDE World Team Rapid & Blitz Chess Championships 2026',
            tourName:
                'FIDE World Team Rapid & Blitz Chess Championships 2026 | Pool A',
            tourSlug:
                'fide-world-team-rapid-blitz-chess-championships-2026-pool-a',
            gameDay: DateTime(2026, 6, 22),
          ),
          _tourGame(
            id: 'pool-b',
            status: GameStatus.ongoing,
            tourId: 'pool-b',
            eventName: 'FIDE World Team Rapid & Blitz Chess Championships 2026',
            tourName:
                'FIDE World Team Rapid & Blitz Chess Championships 2026 | Pool B',
            tourSlug:
                'fide-world-team-rapid-blitz-chess-championships-2026-pool-b',
            gameDay: DateTime(2026, 6, 22),
          ),
        ],
        type: PremiumGamesType.live,
        now: DateTime(2026, 6, 22, 12),
      );

      expect(sections, hasLength(1));
      expect(
        sections.single.title,
        'FIDE World Team Rapid & Blitz Chess Championships 2026',
      );
      expect(sections.single.gameCount, 2);
    });
  });
}

GamesTourModel _tourGame({
  required String id,
  required GameStatus status,
  String tourId = 'tour1',
  String? tourSlug,
  String? tourName,
  String? eventName,
  String? fen,
  String? lastMove,
  int? whiteClockSeconds,
  int? blackClockSeconds,
  DateTime? gameDay,
  DateTime? lastMoveTime,
  int? avgElo,
  int? boardNr,
  String? timeControl,
}) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: PlayerCard(
      name: 'White',
      federation: 'USA',
      title: 'GM',
      rating: 2700,
      countryCode: 'USA',
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: 'Black',
      federation: 'IND',
      title: 'GM',
      rating: 2700,
      countryCode: 'IND',
      team: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    whiteClockSeconds: whiteClockSeconds,
    blackClockSeconds: blackClockSeconds,
    gameStatus: status,
    roundId: 'round1',
    tourId: tourId,
    tourSlug: tourSlug,
    tourName: tourName,
    eventName: eventName,
    fen: fen,
    lastMove: lastMove,
    gameDay: gameDay,
    lastMoveTime: lastMoveTime,
    avgElo: avgElo,
    boardNr: boardNr,
    timeControl: timeControl,
  );
}
