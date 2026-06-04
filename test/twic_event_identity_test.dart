import 'package:chessever/repository/gamebase/search/gamebase_search_models_extra.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/player_profile/utils/twic_event_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TWIC event identity', () {
    test('detects round pairing event titles', () {
      expect(
        isTwicRoundPairingEventTitle(
          'Round 9: Khanin, Semen - Cordova, Emilio',
        ),
        isTrue,
      );
      expect(isTwicRoundPairingEventTitle('35th Chicago Open 2026'), isFalse);
    });

    test('recovers parent event title from Lichess broadcast site', () {
      expect(
        twicEventTitleFromBroadcastSite(
          'https://lichess.org/broadcast/35th-annual-chicago-open/round-9/abc',
        ),
        '35th Annual Chicago Open',
      );
    });

    test(
      'canonical key reconciles broadcast slug titles and database titles',
      () {
        expect(
          twicCanonicalEventKey('35th Annual Chicago Open'),
          twicCanonicalEventKey('35th Chicago Open 2026'),
        );
      },
    );

    test('uses broadcast parent title for round-labeled Gamebase events', () {
      final event = playerEventDataFromGamebaseEvent(
        const GamebaseEventSearchItem(
          id: 'round-9',
          event: 'Round 9: Khanin, Semen - Cordova, Emilio',
          gameCount: 1,
          site:
              'https://lichess.org/broadcast/35th-annual-chicago-open/round-9/abc',
        ),
      );

      expect(event.tourName, '35th Annual Chicago Open');
      expect(event.tourId, '35th Annual Chicago Open');
    });

    test('merges Chicago Open round cards into the canonical event card', () {
      final events = [
        playerEventDataFromGamebaseEvent(
          const GamebaseEventSearchItem(
            id: 'round-9',
            event: 'Round 9: Khanin, Semen - Cordova, Emilio',
            gameCount: 1,
            score: 0,
            site:
                'https://lichess.org/broadcast/35th-annual-chicago-open/round-9/abc',
          ),
        ),
        playerEventDataFromGamebaseEvent(
          const GamebaseEventSearchItem(
            id: 'round-8',
            event: 'Round 8: Cordova, Emilio - Joseph Levine',
            gameCount: 1,
            score: 1,
            site:
                'https://lichess.org/broadcast/35th-annual-chicago-open/round-8/abc',
          ),
        ),
        playerEventDataFromGamebaseEvent(
          GamebaseEventSearchItem(
            id: 'canonical',
            event: '35th Chicago Open 2026',
            gameCount: 6,
            score: 4,
            site: 'Chicago USA',
            startDate: DateTime(2026, 5, 22),
            endDate: DateTime(2026, 5, 24),
          ),
        ),
      ];

      final merged = mergeTwicPlayerEvents(events);

      expect(merged, hasLength(1));
      expect(merged.single.tourName, '35th Chicago Open 2026');
      expect(merged.single.gamesPlayed, 8);
      expect(merged.single.score, 5);
      expect(merged.single.site, 'Chicago USA');
    });
  });
}
