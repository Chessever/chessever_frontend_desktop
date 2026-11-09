import 'package:chessever/desktop/auth/web_sign_in_events_data.dart';
import 'package:flutter_test/flutter_test.dart';

// Decoder-only fixtures, never the signed-out API's data source.
Map<String, dynamic> response(Map<String, dynamic> artwork) => {
  'schemaVersion': 1,
  'dataset': 'for-you',
  'generatedAt': '2026-11-08T20:00:00.123456Z',
  'events': [
    {
      'id': 'fixture-event',
      'created_at': '2026-11-01T00:00:00Z',
      'name': 'Fixture event',
      'max_avg_elo': 2500,
      'date_start': '2026-11-01T00:00:00Z',
      'date_end': '2026-11-30T00:00:00Z',
      'time_control': 'standard',
    },
  ],
  'games': <dynamic>[],
  'strictLiveEventIds': <String>[],
  'artwork': {'fixture-event': artwork},
  'nextRounds': {
    'fixture-event': {
      'name': 'Actual next round',
      'startsAt': '2026-11-08T20:00:00.123457Z',
    },
  },
};

void main() {
  test(
    'location precedes first-tour federation using canonical country names',
    () {
      final data =
          PublicEventsPreview.fromJson(
            response({
              'imageUrl': null,
              'location': 'Prague, Czech Republic',
              'dominantFederation': 'GER',
              'playerCount': 42,
            }),
          ).presentation;
      expect(data.artwork['fixture-event']!.fallbackCountryCode, 'CZ');
      expect(data.artwork['fixture-event']!.playerCount, 42);
      expect(data.capturedAt, DateTime.parse('2026-11-08T20:00:00.123456Z'));
      expect(data.nextRounds['fixture-event']!.name, 'Actual next round');
      expect(
        data.nextRounds['fixture-event']!.startsAt.isAfter(data.capturedAt),
        isTrue,
      );
    },
  );

  test(
    'federation fallback reuses FIDE mappings and unknown-code behavior',
    () {
      for (final entry
          in {'GER': 'DE', 'CZE': 'CZ', 'ENG': 'GB', 'XYZ': 'XY'}.entries) {
        final data =
            PublicEventsPreview.fromJson(
              response({
                'imageUrl': null,
                'location': 'Unknown venue',
                'dominantFederation': entry.key,
                'playerCount': 0,
              }),
            ).presentation;
        expect(data.artwork['fixture-event']!.fallbackCountryCode, entry.value);
      }
    },
  );

  test(
    'real sibling image suppresses flag without discarding location or count',
    () {
      final data =
          PublicEventsPreview.fromJson(
            response({
              'imageUrl': 'https://image.lichess.org/actual.png',
              'location': 'Prague, Czech Republic',
              'dominantFederation': 'GER',
              'playerCount': 42,
            }),
          ).presentation;
      final image = data.artwork['fixture-event']!;
      expect(image.imageUrl, 'https://image.lichess.org/actual.png');
      expect(image.fallbackCountryCode, isNull);
      expect(image.location, 'Prague, Czech Republic');
      expect(image.playerCount, 42);
    },
  );
}
