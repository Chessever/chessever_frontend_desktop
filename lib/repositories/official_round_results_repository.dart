import 'package:chessever/services/official_round_results.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Optional public-table read. No schema/RPC dependency and no external scrape.
class OfficialRoundResultsRepository {
  OfficialRoundResultsRepository(
    this._client, {
    this.pageSize = 50,
    this.timeout = const Duration(seconds: 6),
  });
  final SupabaseClient _client;
  final int pageSize;
  final Duration timeout;
  static const maxRounds = 200;
  static const maxPages = 20;

  /// Any unavailable, legacy, incomplete or oversized snapshot is optional data.
  /// Exact counts prevent a server row cap from masquerading as a final page.
  Future<List<OfficialRoundResults>> getByTourId(
    String tourId, {
    List<OfficialRoundResults> retainedOnFailure = const [],
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(tourId) ||
        pageSize < 1 ||
        pageSize > maxRounds) {
      return const [];
    }
    var expired = false;
    Future<List<OfficialRoundResults>> read() async {
      final tour =
          await _client
              .from('tours')
              .select('id,info,players')
              .eq('id', tourId)
              .maybeSingle();
      if (expired ||
          tour == null ||
          tour['id'] != tourId ||
          tour['info'] is! Map ||
          chessResultsEventKey((tour['info'] as Map)['standings']) == null ||
          tour['players'] is! List ||
          (tour['players'] as List).isEmpty) {
        return const [];
      }
      final rounds = <Object?>[];
      final ids = <String>{};
      int? total;
      for (var page = 0; page < maxPages; page++) {
        final response = await _client
            .from('rounds')
            .select('id,name,slug,tour_id,pairings')
            .eq('tour_id', tourId)
            .order('id', ascending: true)
            .range(rounds.length, rounds.length + pageSize - 1)
            .count(CountOption.exact);
        if (expired) return const [];
        final count = response.count;
        if (count < 0 ||
            count > maxRounds ||
            (total != null && total != count)) {
          return const [];
        }
        total = count;
        final data = response.data;
        if (data.length > pageSize ||
            rounds.length + data.length > count ||
            (data.isEmpty && rounds.length < count)) {
          return const [];
        }
        for (final row in data) {
          final id = row['id'];
          if (id is! String ||
              id.isEmpty ||
              !ids.add(id) ||
              row['tour_id'] != tourId) {
            return const [];
          }
        }
        rounds.addAll(data);
        if (rounds.length == count) {
          return normalizeOfficialRoundResults(tour, rounds);
        }
      }
      return const [];
    }

    try {
      return await read().timeout(
        timeout,
        onTimeout: () {
          expired = true;
          return retainedOnFailure;
        },
      );
    } catch (_) {
      // Preserve the same section's last verified optional data on transport
      // failure. A successful read with invalid provenance still clears it.
      return retainedOnFailure;
    }
  }
}
