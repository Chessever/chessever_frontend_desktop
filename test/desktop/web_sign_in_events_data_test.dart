import 'package:chessever/desktop/auth/web_sign_in_events_data.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:flutter_test/flutter_test.dart';

// Decoder fixtures only. These records never populate the app's public API.
Map<String, dynamic> _event(String id, String name, int elo) => {
  'id': id,
  'created_at': '2026-10-01T00:00:00Z',
  'name': name,
  'max_avg_elo': elo,
  'date_start': '2026-11-01T00:00:00Z',
  'date_end': '2026-11-30T00:00:00Z',
  'time_control': 'standard',
  'search': <String>[],
};
Map<String, dynamic> _game(String id, String eventId) => {
  'id': id,
  'event_id': eventId,
  'round_id': 'fixture-round',
  'round_slug': 'fixture-round',
  'tour_id': 'fixture-tour-$eventId',
  'tour_slug': 'fixture-tour',
  'fen': '4k3/8/8/8/8/8/8/4K3 w - - 0 40',
  'status': '1-0',
  'players': [
    {'name': 'Fixture White', 'rating': 2500},
    {'name': 'Fixture Black', 'rating': 2450},
  ],
};
Map<String, dynamic> _response() => {
  'schemaVersion': 1,
  'dataset': 'for-you',
  'generatedAt': '2026-11-08T20:00:00Z',
  'events': [
    _event('fixture-b', 'Fixture B', 2200),
    _event('fixture-engine', 'Fixture Engine', 3500),
    _event('fixture-a', 'Fixture A', 2500),
  ],
  'games': [
    _game('fixture-b-1', 'fixture-b'),
    _game('fixture-a-2', 'fixture-a'),
    _game('fixture-a-1', 'fixture-a'),
  ],
  'strictLiveEventIds': ['fixture-a'],
  'artwork': {
    'fixture-a': {
      'imageUrl': 'https://image.lichess.org/fixture.png',
      'playerCount': 12,
      'location': 'Fixture venue',
    },
  },
  'nextRounds': {
    'fixture-a': {'name': 'Round 5', 'startsAt': '2026-11-09T12:00:00Z'},
  },
};

void main() {
  test(
    'missing board position stays loading, never a synthetic start board',
    () {
      final raw = _response();
      (raw['games'] as List).last['fen'] = null;
      final data = PublicEventsPreview.fromJson(raw).presentation;
      expect(data.snapshotFor('fixture-a').isLoading, isTrue);
      expect(data.snapshots.containsKey('fixture-a'), isFalse);
    },
  );

  test(
    'real For You projection reuses neutral house sort and RPC board order',
    () {
      final data = PublicEventsPreview.fromJson(_response()).presentation;
      final events = data.forYouEvents.value!;
      expect(events.map((event) => event.id), [
        'fixture-a',
        'fixture-b',
        'fixture-engine',
      ]);
      expect(events.first.tourEventCategory, TourEventCategory.live);
      expect(
        data.snapshots['fixture-a']!.visibleGames.map((game) => game.gameId),
        ['fixture-a-2', 'fixture-a-1'],
      );
      expect(data.snapshots['fixture-engine']!.visibleGames, isEmpty);
      expect(data.artwork['fixture-a']!.playerCount, 12);
      expect(data.nextRounds['fixture-a']!.name, 'Round 5');
      expect(data.capturedAt, DateTime.utc(2026, 11, 8, 20));
    },
  );

  test('Current data cannot be relabelled as the default For You dataset', () {
    final raw = _response()..['dataset'] = 'current';
    expect(() => PublicEventsPreview.fromJson(raw), throwsFormatException);
  });

  test('unresolved game data is unavailable rather than resolved empty', () {
    final raw = _response()..remove('games');
    expect(() => PublicEventsPreview.fromJson(raw), throwsFormatException);
  });

  test('unknown live-status provenance cannot become confirmed not live', () {
    final raw = _response()..remove('strictLiveEventIds');
    expect(() => PublicEventsPreview.fromJson(raw), throwsFormatException);
  });

  test('a game cannot move to an unrelated event', () {
    final raw = _response();
    (raw['games'] as List).first['event_id'] = 'unrelated-event';
    expect(() => PublicEventsPreview.fromJson(raw), throwsFormatException);
  });
}
