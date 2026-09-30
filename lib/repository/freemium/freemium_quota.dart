import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Storage allowances enforced by `public.check_freemium_quota` and the quota
/// triggers. Favourite EVENTS are unlimited and deliberately absent.
enum FreemiumQuotaKind {
  savedGames('saved_games', 'saved games'),
  favoritePlayers('favorite_players', 'favorite players'),
  ownedDatabases('owned_databases', 'databases');

  const FreemiumQuotaKind(this.wireName, this.noun);

  /// The `p_kind` value the server expects.
  final String wireName;

  /// Plural noun for capacity copy ("10 of 10 saved games used").
  final String noun;

  static FreemiumQuotaKind? fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

/// Mirrors the desktop access outcomes that a storage quota can produce.
///
/// There is no `premiumRequired` here: storage is never premium-only, it is
/// only capped. An operational failure is [temporarilyUnavailable] (Retry),
/// never a purchase prompt.
enum FreemiumQuotaOutcome {
  allowed,
  accountRequired,
  quotaExceeded,
  temporarilyUnavailable,
}

/// Where a result came from. [clientFallback] exists only while the server
/// function is not deployed; see [FreemiumQuotaResult.source].
enum FreemiumQuotaSource { server, clientFallback }

/// The server's `{allowed, reason, used, limit, is_premium}` answer, kept whole
/// so the paywall can name the exhausted allowance instead of a generic wall.
@immutable
class FreemiumQuotaResult {
  const FreemiumQuotaResult({
    required this.kind,
    required this.outcome,
    required this.reason,
    required this.requested,
    required this.source,
    this.used,
    this.limit,
    this.isPremium = false,
  });

  /// Maps a `check_freemium_quota` response. Anything unparseable is
  /// [FreemiumQuotaOutcome.temporarilyUnavailable]; it never grants a slot.
  factory FreemiumQuotaResult.fromServer(
    FreemiumQuotaKind kind,
    int requested,
    Object? response,
  ) {
    final json = _jsonMap(response);
    if (json == null) {
      return FreemiumQuotaResult.unavailable(
        kind,
        requested,
        reason: 'invalid_response',
      );
    }
    final allowed = json['allowed'] == true;
    final reason = json['reason'] is String ? json['reason'] as String : '';
    final outcome =
        allowed
            ? FreemiumQuotaOutcome.allowed
            : switch (reason) {
              'quota_exceeded' => FreemiumQuotaOutcome.quotaExceeded,
              'auth_required' => FreemiumQuotaOutcome.accountRequired,
              _ => FreemiumQuotaOutcome.temporarilyUnavailable,
            };
    return FreemiumQuotaResult(
      kind: FreemiumQuotaKind.fromWire(json['kind']) ?? kind,
      outcome: outcome,
      reason: reason.isEmpty ? 'unknown' : reason,
      requested: _int(json['requested']) ?? requested,
      used: _int(json['used']),
      limit: _int(json['limit']),
      isPremium: json['is_premium'] == true,
      source: FreemiumQuotaSource.server,
    );
  }

  factory FreemiumQuotaResult.unavailable(
    FreemiumQuotaKind kind,
    int requested, {
    required String reason,
    FreemiumQuotaSource source = FreemiumQuotaSource.server,
  }) => FreemiumQuotaResult(
    kind: kind,
    outcome: FreemiumQuotaOutcome.temporarilyUnavailable,
    reason: reason,
    requested: requested,
    source: source,
  );

  final FreemiumQuotaKind kind;
  final FreemiumQuotaOutcome outcome;

  /// Stable server reason (`premium`, `no_new_slot`, `within_limit`,
  /// `quota_exceeded`, `auth_required`, ...) or a client-side reason.
  final String reason;
  final int requested;
  final int? used;
  final int? limit;
  final bool isPremium;
  final FreemiumQuotaSource source;

  bool get isAllowed => outcome == FreemiumQuotaOutcome.allowed;

  /// "10 of 10 saved games used", or null when either side is unknown.
  String? get capacityLabel {
    final used = this.used;
    final limit = this.limit;
    if (used == null || limit == null || isPremium) return null;
    return '$used of $limit ${kind.noun} used';
  }

  @override
  String toString() =>
      'FreemiumQuotaResult(${kind.wireName}, $outcome, $reason, '
      'used: $used, limit: $limit, requested: $requested, $source)';
}

/// Error message the quota triggers raise when a write loses the race for the
/// last slot.
const String kFreemiumQuotaExceededMessage = 'freemium_quota_exceeded';

/// Whether [error] means the quota RPC is not deployed.
///
/// Deliberately narrow: PostgREST answers `PGRST202` when the function is not
/// in its schema cache, Postgres answers `42883` (undefined_function). Network
/// failures, timeouts and every other database error are NOT this, and must
/// surface as Retry rather than silently switching to the client count.
bool isMissingFreemiumQuotaFunction(Object error) =>
    error is PostgrestException &&
    (error.code == 'PGRST202' || error.code == '42883');

/// The capacity a quota trigger attached to a rejected write, or null when
/// [error] is not a quota rejection.
///
/// Repositories built on `BaseRepository` rewrap Postgres errors into a
/// message-only exception, so the message is matched too; capacity is then
/// unknown and only [fallbackKind] is reported.
FreemiumQuotaResult? freemiumQuotaRejection(
  Object error, {
  required FreemiumQuotaKind fallbackKind,
  int requested = 1,
}) {
  if (error is PostgrestException) {
    if (error.message != kFreemiumQuotaExceededMessage) return null;
    final detail = FreemiumQuotaResult.fromServer(
      FreemiumQuotaKind.fromWire(error.hint) ?? fallbackKind,
      requested,
      error.details,
    );
    return FreemiumQuotaResult(
      kind: detail.kind,
      outcome: FreemiumQuotaOutcome.quotaExceeded,
      reason: 'quota_exceeded',
      requested: detail.requested,
      used: detail.used,
      limit: detail.limit,
      source: FreemiumQuotaSource.server,
    );
  }
  if (!error.toString().contains(kFreemiumQuotaExceededMessage)) return null;
  return FreemiumQuotaResult(
    kind: fallbackKind,
    outcome: FreemiumQuotaOutcome.quotaExceeded,
    reason: 'quota_exceeded',
    requested: requested,
    source: FreemiumQuotaSource.server,
  );
}

/// One short line for a blocked storage action. The paywall (when it opened)
/// carries the full explanation; this is what stays on screen afterwards.
String freemiumQuotaBlockedMessage(FreemiumQuotaResult result) {
  switch (result.outcome) {
    case FreemiumQuotaOutcome.allowed:
      return '';
    case FreemiumQuotaOutcome.quotaExceeded:
      final capacity = result.capacityLabel;
      return capacity == null
          ? 'Free ${result.kind.noun} limit reached. Premium removes it.'
          : '$capacity. Premium removes the limit.';
    case FreemiumQuotaOutcome.accountRequired:
      return 'Sign in to add ${result.kind.noun} to your cloud library.';
    case FreemiumQuotaOutcome.temporarilyUnavailable:
      return "Couldn't check your ${result.kind.noun} allowance. Try again.";
  }
}

Map<String, dynamic>? _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String && value.isNotEmpty) {
    try {
      return _jsonMap(jsonDecode(value));
    } catch (_) {
      return null;
    }
  }
  return null;
}

int? _int(Object? value) => value is num ? value.toInt() : null;

/// Thrown by domain code that cannot open UI when the quota answer is unknown.
/// Callers show Retry, never a purchase prompt.
class FreemiumQuotaUnavailableException implements Exception {
  const FreemiumQuotaUnavailableException(this.result);

  final FreemiumQuotaResult result;

  @override
  String toString() => freemiumQuotaBlockedMessage(result);
}
