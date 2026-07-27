import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';

/// A TWIC/Gamebase player event carries the event *title* as its `tourId`.
PlayerEventData _twicEvent(String title, {int games = 4}) {
  return PlayerEventData(
    tourId: title,
    tourName: title,
    tourSlug: title,
    gamesPlayed: games,
  );
}

GroupBroadcast _broadcast(String id, String name) {
  return GroupBroadcast(
    id: id,
    createdAt: DateTime.utc(2026, 6, 17),
    name: name,
    search: const <String>[],
    dateStart: DateTime.utc(2026, 6, 17),
    dateEnd: DateTime.utc(2026, 6, 21),
  );
}

void main() {
  test('a TWIC event adopts the real broadcast id, never a synthetic one', () {
    // Regression: the card used to carry `twic_event_<title>`, which resolves to
    // zero tours in the Tournament Detail chain and rendered "No rounds yet"
    // when the event was opened from a player profile.
    const title = 'FIDE World Team Rapid & Blitz Chess Championships 2026';
    final cards = buildTwicEventCards(
      events: [_twicEvent(title, games: 30)],
      broadcasts: [
        _broadcast('fide_world_team_rapid_blitz_chess_championships_2026', title),
      ],
    );

    expect(cards, hasLength(1));
    final card = cards[title]!;
    expect(card.id, 'fide_world_team_rapid_blitz_chess_championships_2026');
    expect(card.id, isNot(startsWith('twic_event_')));
    expect(card.eventSource, EventSource.lichessBroadcast);
    expect(card.title, title);
  });

  test('an event with no broadcast coverage yields no card', () {
    // No card means the profile row stays non-openable, which is correct: there
    // is nothing for the Tournament Detail pane to load.
    final cards = buildTwicEventCards(
      events: [_twicEvent('GCT Super ROM Classic')],
      broadcasts: [_broadcast('some_other_event', 'Some Other Event')],
    );

    expect(cards, isEmpty);
  });

  test('only the covered events survive a mixed profile', () {
    final cards = buildTwicEventCards(
      events: [
        _twicEvent('Titled Tuesday June 2 2026'),
        _twicEvent('Super Chess Classic Romania'),
        _twicEvent('FIDE Candidates 2026'),
      ],
      broadcasts: [
        _broadcast('titled_tuesday_june_2_2026', 'Titled Tuesday June 2 2026'),
        _broadcast('fide_candidates_2026', 'FIDE Candidates 2026'),
      ],
    );

    expect(cards.keys, unorderedEquals(<String>[
      'Titled Tuesday June 2 2026',
      'FIDE Candidates 2026',
    ]));
    expect(cards['Super Chess Classic Romania'], isNull);
  });

  test('title matching tolerates case and whitespace differences', () {
    final cards = buildTwicEventCards(
      events: [_twicEvent('  fide   candidates 2026 ')],
      broadcasts: [_broadcast('fide_candidates_2026', 'FIDE Candidates 2026')],
    );

    expect(cards.values.single.id, 'fide_candidates_2026');
  });

  test('an empty broadcast list never invents a card', () {
    final cards = buildTwicEventCards(
      events: [_twicEvent('FIDE Candidates 2026')],
      broadcasts: const <GroupBroadcast>[],
    );

    expect(cards, isEmpty);
  });

  test('duplicate broadcast names resolve deterministically to the first', () {
    final cards = buildTwicEventCards(
      events: [_twicEvent('Titled Tuesday June 2 2026')],
      broadcasts: [
        _broadcast('first_match', 'Titled Tuesday June 2 2026'),
        _broadcast('second_match', 'Titled Tuesday June 2 2026'),
      ],
    );

    expect(cards.values.single.id, 'first_match');
  });
}
