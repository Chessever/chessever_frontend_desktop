import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _canonicalGameId = 'fe6351a5-6354-4c16-b7f6-9124e5d9a9ef';

GamesTourModel _game({
  String gameId = _canonicalGameId,
  GameSource source = GameSource.supabase,
  String? tourSlug = 'paracin-2026-open-a',
  String? roundSlug = 'round-4',
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
    gameStatus: GameStatus.whiteWins,
    roundId: 'round-4',
    roundSlug: roundSlug,
    tourId: 'tour-1',
    tourSlug: tourSlug,
    tourName: '19. International Tournament Paracin 2026 - Open A',
    eventName: '19. International Tournament Paracin 2026 - Open A',
  );
}

void main() {
  group('buildDesktopGameShareUrl', () {
    test('keeps canonical event links for smart-surface Gamebase rows', () {
      final url = buildDesktopGameShareUrl(
        game: _game(source: GameSource.gamebase),
      );

      expect(
        url,
        'https://chessever.com/games/$_canonicalGameId?tour=paracin-2026-open-a&round=round-4',
      );
    });

    test('still rejects non-shareable local smart rows', () {
      expect(
        buildDesktopGameShareUrl(
          game: _game(
            gameId: 'gamebase-miniature-1',
            source: GameSource.gamebase,
          ),
        ),
        isNull,
      );
    });
  });
}
