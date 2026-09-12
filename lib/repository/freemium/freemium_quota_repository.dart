import 'dart:async';

import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/repository/freemium/freemium_quota_queue.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:chessever/utils/library_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Calls the quota RPC: `(kind, additions) -> jsonb`.
typedef FreemiumQuotaRpc = Future<Object?> Function(String kind, int additions);

/// Counts current usage for the temporary client fallback.
typedef FreemiumQuotaUsageCounter =
    Future<int> Function(FreemiumQuotaKind kind);

/// Thrown by a usage counter when there is no Supabase session at all.
class FreemiumQuotaNoSessionException implements Exception {
  const FreemiumQuotaNoSessionException();
}

final freemiumQuotaRepositoryProvider = Provider<FreemiumQuotaRepository>(
  (ref) => FreemiumQuotaRepository(
    fallbackIsSubscribed: () => ref.read(subscriptionProvider).isSubscribed,
  ),
);

/// The most recent storage denial that is about to open the paywall.
///
/// The paywall entry points take only a `BuildContext`, so the denial's
/// capacity (`used`, `limit`, `kind`) is published here for the paywall to
/// render "10 of 10 saved games used". Set immediately before the paywall
/// opens and cleared when it closes.
final freemiumQuotaDenialProvider = StateProvider<FreemiumQuotaResult?>(
  (ref) => null,
);

/// Server-authorized storage admission for saved games, favourite players and
/// owned databases.
///
/// The authority is `public.check_freemium_quota(p_kind text, p_additions
/// integer) RETURNS jsonb` plus the enforcement triggers described in
/// `docs/freemium_quota_contract.sql`. **That function is NOT YET DEPLOYED.**
/// Until it is, PostgREST reports it missing and this repository uses a
/// clearly-labelled temporary client count ([_temporaryClientFallback]).
class FreemiumQuotaRepository {
  FreemiumQuotaRepository({
    FreemiumQuotaRpc? rpc,
    FreemiumQuotaUsageCounter? fallbackUsage,
    bool Function()? fallbackIsSubscribed,
    FreemiumQuotaQueue? queue,
  }) : _rpc = rpc ?? _supabaseRpc,
       _fallbackUsage = fallbackUsage ?? _supabaseFallbackUsage,
       _fallbackIsSubscribed = fallbackIsSubscribed ?? _notSubscribed,
       _queue = queue ?? sharedQueue;

  /// The server function this repository calls.
  static const String rpcName = 'check_freemium_quota';

  /// One FIFO per isolate, shared by every repository instance so a single
  /// process cannot race itself between the check and the write.
  static final FreemiumQuotaQueue sharedQueue = FreemiumQuotaQueue();

  final FreemiumQuotaRpc _rpc;
  final FreemiumQuotaUsageCounter _fallbackUsage;
  final bool Function() _fallbackIsSubscribed;
  final FreemiumQuotaQueue _queue;

  /// Whether [additions] more records of [kind] may be stored.
  ///
  /// Zero additions (edit, rename, re-save, export, move within counted
  /// storage) are always allowed by the server, including over the limit.
  Future<FreemiumQuotaResult> check(
    FreemiumQuotaKind kind, {
    int additions = 1,
  }) => _queue.run(() => _check(kind, additions));

  Future<FreemiumQuotaResult> _check(
    FreemiumQuotaKind kind,
    int additions,
  ) async {
    if (additions < 0) {
      return FreemiumQuotaResult.unavailable(
        kind,
        additions,
        reason: 'invalid_additions',
      );
    }
    final Object? response;
    try {
      response = await _rpc(kind.wireName, additions);
    } catch (error) {
      if (isMissingFreemiumQuotaFunction(error)) {
        return _temporaryClientFallback(kind, additions);
      }
      debugPrint('[FreemiumQuota] $rpcName failed for ${kind.wireName}: $error');
      return FreemiumQuotaResult.unavailable(
        kind,
        additions,
        reason: 'request_failed',
      );
    }
    return FreemiumQuotaResult.fromServer(kind, additions, response);
  }

  // ===========================================================================
  // TEMPORARY CLIENT FALLBACK. Delete this section (and the fallback
  // constructor parameters) once `check_freemium_quota` is deployed.
  //
  // Reached ONLY when the server reports the function missing. It is not
  // atomic: two devices can both pass it. It applies the same exclusions as
  // the SQL (Likes, folder nodes and followed books are not counted) against
  // the existing shared client constants: `kFreeSavedGamesLimit`,
  // `kFreeFavoriteLimit` and `kFreeBookCreationLimit`.
  // ===========================================================================
  Future<FreemiumQuotaResult> _temporaryClientFallback(
    FreemiumQuotaKind kind,
    int additions,
  ) async {
    debugPrint(
      '[FreemiumQuota] $rpcName is not deployed; using the temporary client '
      'count for ${kind.wireName}',
    );
    if (_fallbackIsSubscribed()) {
      return FreemiumQuotaResult(
        kind: kind,
        outcome: FreemiumQuotaOutcome.allowed,
        reason: 'premium',
        requested: additions,
        isPremium: true,
        source: FreemiumQuotaSource.clientFallback,
      );
    }

    final int used;
    try {
      used = await _fallbackUsage(kind);
    } on FreemiumQuotaNoSessionException {
      return FreemiumQuotaResult(
        kind: kind,
        outcome: FreemiumQuotaOutcome.accountRequired,
        reason: 'auth_required',
        requested: additions,
        source: FreemiumQuotaSource.clientFallback,
      );
    } catch (error) {
      debugPrint('[FreemiumQuota] fallback count failed: $error');
      return FreemiumQuotaResult.unavailable(
        kind,
        additions,
        reason: 'request_failed',
        source: FreemiumQuotaSource.clientFallback,
      );
    }

    final int limit = switch (kind) {
      FreemiumQuotaKind.savedGames => kFreeSavedGamesLimit,
      FreemiumQuotaKind.favoritePlayers => kFreeFavoriteLimit,
      FreemiumQuotaKind.ownedDatabases => kFreeBookCreationLimit,
    };
    final FreemiumQuotaOutcome outcome;
    final String reason;
    if (additions == 0) {
      outcome = FreemiumQuotaOutcome.allowed;
      reason = 'no_new_slot';
    } else if (used + additions <= limit) {
      outcome = FreemiumQuotaOutcome.allowed;
      reason = 'within_limit';
    } else {
      outcome = FreemiumQuotaOutcome.quotaExceeded;
      reason = 'quota_exceeded';
    }
    return FreemiumQuotaResult(
      kind: kind,
      outcome: outcome,
      reason: reason,
      requested: additions,
      used: used,
      limit: limit,
      source: FreemiumQuotaSource.clientFallback,
    );
  }
}

Future<Object?> _supabaseRpc(String kind, int additions) =>
    Supabase.instance.client.rpc(
      FreemiumQuotaRepository.rpcName,
      params: <String, dynamic>{'p_kind': kind, 'p_additions': additions},
    );

bool _notSubscribed() => false;

/// TEMPORARY CLIENT FALLBACK counter. See [FreemiumQuotaRepository].
Future<int> _supabaseFallbackUsage(FreemiumQuotaKind kind) async {
  final client = Supabase.instance.client;
  final userId = client.auth.currentUser?.id;
  if (userId == null) throw const FreemiumQuotaNoSessionException();

  if (kind == FreemiumQuotaKind.favoritePlayers) {
    return client
        .from('user_favorite_players')
        .count(CountOption.exact)
        .eq('user_id', userId);
  }

  final rows = await client
      .from('user_folders')
      .select('id, node_type, is_liked_games')
      .eq('user_id', userId);
  final folders = <Map<String, Object?>>[
    for (final row in rows) Map<String, Object?>.from(row),
  ];
  if (kind == FreemiumQuotaKind.ownedDatabases) {
    return freemiumFallbackOwnedDatabaseCount(folders);
  }
  final counted = freemiumFallbackCountedGameFolderIds(folders);
  if (counted.isEmpty) return 0;
  return client
      .from('user_saved_analyses')
      .count(CountOption.exact)
      .eq('user_id', userId)
      .inFilter('folder_id', counted);
}

/// Owned folder ids whose games count as saved games: every owned node except
/// the Likes collection. Rows must be the account's own `user_folders` rows,
/// so followed books are already absent.
@visibleForTesting
List<String> freemiumFallbackCountedGameFolderIds(
  Iterable<Map<String, Object?>> ownedFolderRows,
) => <String>[
  for (final row in ownedFolderRows)
    if (row['is_liked_games'] != true && row['id'] != null)
      row['id'].toString(),
];

/// Owned database nodes, excluding folder nodes and the Likes collection.
@visibleForTesting
int freemiumFallbackOwnedDatabaseCount(
  Iterable<Map<String, Object?>> ownedFolderRows,
) =>
    ownedFolderRows
        .where(
          (row) =>
              row['is_liked_games'] != true &&
              (row['node_type'] ?? 'database') == 'database',
        )
        .length;
