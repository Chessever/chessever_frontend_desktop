import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

enum FideRatingHistoryType {
  classical('standard'),
  rapid('rapid'),
  blitz('blitz');

  const FideRatingHistoryType(this.apiValue);

  final String apiValue;
}

class FideRatingHistoryPoint {
  const FideRatingHistoryPoint({
    required this.month,
    required this.rating,
    required this.games,
  });

  final DateTime month;
  final int rating;
  final int? games;
}

class FideRatingCardTrend {
  const FideRatingCardTrend({
    required this.series,
    required this.current,
    required this.change,
    required this.games,
  });

  final List<FideRatingHistoryPoint> series;
  final int? current;
  final int? change;
  final int? games;
}

class FideRatingHistory {
  const FideRatingHistory(this._series);

  final Map<FideRatingHistoryType, List<FideRatingHistoryPoint>> _series;

  List<FideRatingHistoryPoint> seriesFor(FideRatingHistoryType type) =>
      _series[type] ?? const [];

  List<FideRatingHistoryPoint> chartSeries(
    FideRatingHistoryType type, {
    int? months,
  }) {
    final all = seriesFor(type);
    if (all.isEmpty || months == null) return all;
    final latestMonth = _monthIndex(all.last.month);
    return all
        .where((point) => _monthIndex(point.month) >= latestMonth - months)
        .toList(growable: false);
  }

  FideRatingCardTrend cardTrend(FideRatingHistoryType type) {
    final all = seriesFor(type);
    if (all.isEmpty) {
      return const FideRatingCardTrend(
        series: [],
        current: null,
        change: null,
        games: null,
      );
    }

    final latestMonth = _monthIndex(all.last.month);
    final visible = all
        .where((point) => _monthIndex(point.month) >= latestMonth - 12)
        .toList(growable: false);
    final change =
        visible.length == 13
            ? visible.last.rating - visible.first.rating
            : null;
    final gameMonths = all
        .where((point) => _monthIndex(point.month) >= latestMonth - 11)
        .toList(growable: false);
    final hasCompleteGameCounts =
        gameMonths.isNotEmpty &&
        gameMonths.every((point) => point.games != null);
    final games =
        hasCompleteGameCounts
            ? gameMonths.fold<int>(0, (sum, point) => sum + point.games!)
            : null;

    return FideRatingCardTrend(
      series: visible,
      current: visible.last.rating,
      change: change,
      games: games,
    );
  }
}

class FideRatingHistoryService {
  FideRatingHistoryService._();

  static const _timeout = Duration(seconds: 10);
  static final Map<int, Future<FideRatingHistory>> _cache = {};

  static Future<FideRatingHistory> fetch(int fideId) {
    final cached = _cache[fideId];
    if (cached != null) return cached;
    final request = _fetch(fideId);
    _cache[fideId] = request;
    return request.catchError((Object error) {
      _cache.remove(fideId);
      throw error;
    });
  }

  static Future<FideRatingHistory> _fetch(int fideId) async {
    final entries = await Future.wait(
      FideRatingHistoryType.values.map((type) async {
        try {
          final uri = Uri.https(
            'fideratings.com',
            '/api/player/$fideId/history',
            {'type': type.apiValue},
          );
          final response = await http
              .get(uri, headers: const {'accept': 'application/json'})
              .timeout(_timeout);
          if (response.statusCode != 200) {
            return MapEntry<
              FideRatingHistoryType,
              List<FideRatingHistoryPoint>
            >(type, const []);
          }
          return MapEntry<FideRatingHistoryType, List<FideRatingHistoryPoint>>(
            type,
            parseFideRatingHistoryResponse(response.body),
          );
        } catch (_) {
          return MapEntry<FideRatingHistoryType, List<FideRatingHistoryPoint>>(
            type,
            const [],
          );
        }
      }),
    );
    final result =
        Map<FideRatingHistoryType, List<FideRatingHistoryPoint>>.fromEntries(
          entries,
        );
    if (result.values.every((series) => series.isEmpty)) {
      throw StateError('FIDE rating history is unavailable.');
    }
    return FideRatingHistory(result);
  }
}

List<FideRatingHistoryPoint> parseFideRatingHistoryResponse(String raw) {
  final clean = raw.replaceFirst('\uFEFF', '').trim();
  final decoded = jsonDecode(clean);
  if (decoded is! Map) return const [];
  final history = decoded['history'];
  if (history is! List) return const [];

  final byMonth = <String, FideRatingHistoryPoint>{};
  for (final value in history) {
    if (value is! Map) continue;
    final date = value['date']?.toString();
    final match =
        date == null ? null : RegExp(r'^(\d{4})-(\d{2})$').firstMatch(date);
    if (match == null) continue;
    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final rating = int.tryParse(value['rating']?.toString() ?? '');
    final gamesRaw = value['games'];
    final games =
        gamesRaw == null || gamesRaw.toString().isEmpty
            ? null
            : int.tryParse(gamesRaw.toString());
    if (year == null ||
        month == null ||
        month < 1 ||
        month > 12 ||
        rating == null ||
        rating <= 0 ||
        (games != null && games < 0)) {
      continue;
    }
    byMonth[date!] = FideRatingHistoryPoint(
      month: DateTime.utc(year, month),
      rating: rating,
      games: games,
    );
  }
  final result = byMonth.values.toList(growable: false)
    ..sort((a, b) => a.month.compareTo(b.month));
  return result;
}

int _monthIndex(DateTime value) => value.year * 12 + value.month - 1;

final fideRatingHistoryProvider = FutureProvider.autoDispose
    .family<FideRatingHistory, int>((ref, fideId) {
      return FideRatingHistoryService.fetch(fideId);
    });
