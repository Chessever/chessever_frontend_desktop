import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/repository/supabase/round/round_repository.dart';

String playerHoverRoundsKey(Iterable<String> tourIds) =>
    jsonEncode(tourIds.toSet().toList()..sort());

/// Display metadata only. Preserve the original name, not a repaired slug/name.
class PlayerHoverRound {
  const PlayerHoverRound({required this.id, required this.name, this.startsAt});

  final String id;
  final String name;
  final DateTime? startsAt;
}

int? explicitPlayerHoverRoundNumber(String name) {
  final match = RegExp(
    r'^(?:round\s*|r\s*)?(\d+)$',
    caseSensitive: false,
  ).firstMatch(name.trim());
  final number = int.tryParse(match?.group(1) ?? '');
  return number != null && number > 0 ? number : null;
}

/// Web player-hover-layout.ts at 715a8f7d8643c0476ca33d4fe132106d0d585011.
/// Complete event schedule, never the player's games or a sampled Board rail.
/// Inferred R labels are event-order positions, NOT official round numbers.
Map<String, String> playerHoverRoundLabels(List<PlayerHoverRound> rounds) {
  final ordered = rounds.indexed.toList();
  ordered.sort((a, b) {
    final an = explicitPlayerHoverRoundNumber(a.$2.name);
    final bn = explicitPlayerHoverRoundNumber(b.$2.name);
    if (an != null && bn != null) {
      final order = an.compareTo(bn);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    }
    final startA = a.$2.startsAt;
    final startB = b.$2.startsAt;
    if (startA != null && startB != null) {
      final order = startA.compareTo(startB);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    }
    return a.$1.compareTo(b.$1);
  });
  final labels = <String, String>{};
  final scheduledNames = <(int, String), String>{};
  final reserved =
      rounds.map((r) => explicitPlayerHoverRoundNumber(r.name)).toSet();
  var ordinal = 0;
  for (final (_, round) in ordered) {
    final key =
        round.startsAt != null && round.name.isNotEmpty
            ? (round.startsAt!.millisecondsSinceEpoch, round.name)
            : null;
    final duplicate = key == null ? null : scheduledNames[key];
    final explicit = explicitPlayerHoverRoundNumber(round.name);
    if (duplicate == null) {
      if (explicit != null) {
        if (explicit > ordinal) ordinal = explicit;
      } else {
        do {
          ordinal++;
        } while (reserved.contains(ordinal));
      }
    }
    final label = duplicate ?? 'R${explicit ?? ordinal}';
    labels[round.id] = label;
    if (key != null) scheduledNames[key] = label;
  }
  return labels;
}

/// Publish only complete pagination. A failed page yields no inferred labels.
Future<List<PlayerHoverRound>> loadPlayerHoverRounds(
  Future<List<Map<String, dynamic>>> Function(int offset, int size) fetchPage,
) async {
  const pageSize = 200;
  final result = <PlayerHoverRound>[];
  var offset = 0;
  while (true) {
    final page = await fetchPage(offset, pageSize);
    result.addAll(
      page.map(
        (row) => PlayerHoverRound(
          id: row['id'] as String,
          name: row['name'] as String? ?? '',
          startsAt: DateTime.tryParse(row['starts_at'] as String? ?? ''),
        ),
      ),
    );
    // Continue through short server-capped pages, stopping only at empty.
    if (page.isEmpty) return result;
    offset += page.length;
  }
}

/// Visibility-owned by the compact card; same event key for both players.
/// Uses only the existing public rounds table/columns (no new backend API).
final playerHoverRoundsProvider = FutureProvider.autoDispose
    .family<List<PlayerHoverRound>, String>((ref, encodedTourIds) {
      final tourIds = (jsonDecode(encodedTourIds) as List).cast<String>();
      final client = ref.read(roundRepositoryProvider).supabase;
      var disposed = false;
      ref.onDispose(() => disposed = true);
      return loadPlayerHoverRounds((offset, size) async {
        if (disposed) throw StateError('Player preview closed');
        return await client
            .from('rounds')
            .select('id,name,starts_at')
            .inFilter('tour_id', tourIds)
            .order('created_at', ascending: true)
            .order('id', ascending: true)
            .range(offset, offset + size - 1);
      });
    });
