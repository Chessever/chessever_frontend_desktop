import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCountryGameDay', () {
    test('reads the newest game_day row', () {
      expect(
        parseCountryGameDay([
          {'game_day': '2026-09-14'},
        ]),
        DateTime(2026, 9, 14),
      );
    });

    test('returns null for an empty or malformed payload', () {
      expect(parseCountryGameDay(null), isNull);
      expect(parseCountryGameDay(const <Object>[]), isNull);
      expect(
        parseCountryGameDay([
          {'date_start': '2026-09-14'},
        ]),
        isNull,
      );
    });
  });

  group('walkNewestCountryDays', () {
    final days = [
      DateTime(2026, 9, 14),
      DateTime(2026, 9, 13),
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 10),
    ];

    Future<DateTime?> probe(DateTime? before) async {
      if (before == null) return days.first;
      for (final day in days) {
        if (day.isBefore(DateTime(before.year, before.month, before.day))) {
          return day;
        }
      }
      return null;
    }

    test(
      'collects newest-first days without scanning the full history',
      () async {
        final dates = await walkNewestCountryDays(limit: 3, probe: probe);
        expect(dates, [days[0], days[1], days[2]]);
      },
    );

    test(
      'continues strictly older than the already-loaded oldest day',
      () async {
        final dates = await walkNewestCountryDays(
          limit: 2,
          before: days[1],
          probe: probe,
        );
        expect(dates, [days[2], days[3]]);
      },
    );

    test('skip walks past the newest dates before collecting', () async {
      final dates = await walkNewestCountryDays(
        limit: 2,
        skip: 2,
        probe: probe,
      );
      expect(dates, [days[2], days[3]]);
    });

    test('stops when the probe returns null', () async {
      final dates = await walkNewestCountryDays(limit: 10, probe: probe);
      expect(dates, days);
    });

    test('stops if the probe does not move strictly older', () async {
      final dates = await walkNewestCountryDays(
        limit: 5,
        probe: (_) async => DateTime(2026, 9, 14),
      );
      expect(dates, [DateTime(2026, 9, 14)]);
    });
  });

  test('countrymen day list projection omits PGN', () {
    expect(
      RegExp(r'\bpgn\b').hasMatch(countrymenDaySelectColumnsForTesting),
      isFalse,
    );
  });
}
