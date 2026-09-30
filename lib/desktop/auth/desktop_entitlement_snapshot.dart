import 'package:flutter/foundation.dart' show immutable;

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';

/// Measured usage of the current account's free-tier allowances.
///
/// Every counter is nullable: null means "not measured" and a quota request
/// against an unmeasured counter is `temporarilyUnavailable`, never a free
/// pass. Counts come from a fresh authoritative COUNT at admission time, not
/// from a cached realtime list that lags a just-completed insert.
///
/// What is NOT counted is part of the contract, and callers measuring these
/// must exclude it:
/// * [favoritePlayers] - favourite EVENTS are unlimited and uncounted.
/// * [cloudDatabases] - folders, followed shared books, TWIC and the Likes
///   collection (`is_liked_games`, never matched by display name) are
///   uncounted.
/// * [cloudSavedGames] - Likes rows are uncounted.
@immutable
class DesktopUsage {
  const DesktopUsage({
    this.favoritePlayers,
    this.cloudDatabases,
    this.cloudSavedGames,
    this.gameReportsOnUtcDay,
    this.existingReportForRequestedGame = false,
  });

  /// Nothing measured.
  static const DesktopUsage unknown = DesktopUsage();

  final int? favoritePlayers;
  final int? cloudDatabases;
  final int? cloudSavedGames;

  /// Distinct NEW game fingerprints reported on the current UTC day.
  final int? gameReportsOnUtcDay;

  /// The requested game already has a stored report, so opening or
  /// recomputing it does not spend the daily slot.
  final bool existingReportForRequestedGame;

  /// The measured count for [quota], or null when unmeasured or not a
  /// counted allowance.
  int? usedFor(DesktopQuota quota) {
    switch (quota) {
      case DesktopQuota.none:
        return null;
      case DesktopQuota.favoritePlayers:
        return favoritePlayers;
      case DesktopQuota.cloudDatabases:
        return cloudDatabases;
      case DesktopQuota.cloudSavedGames:
        return cloudSavedGames;
      case DesktopQuota.gameReportsPerUtcDay:
        return gameReportsOnUtcDay;
    }
  }

  DesktopUsage copyWith({
    int? favoritePlayers,
    int? cloudDatabases,
    int? cloudSavedGames,
    int? gameReportsOnUtcDay,
    bool? existingReportForRequestedGame,
  }) {
    return DesktopUsage(
      favoritePlayers: favoritePlayers ?? this.favoritePlayers,
      cloudDatabases: cloudDatabases ?? this.cloudDatabases,
      cloudSavedGames: cloudSavedGames ?? this.cloudSavedGames,
      gameReportsOnUtcDay: gameReportsOnUtcDay ?? this.gameReportsOnUtcDay,
      existingReportForRequestedGame:
          existingReportForRequestedGame ??
          this.existingReportForRequestedGame,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopUsage &&
          other.favoritePlayers == favoritePlayers &&
          other.cloudDatabases == cloudDatabases &&
          other.cloudSavedGames == cloudSavedGames &&
          other.gameReportsOnUtcDay == gameReportsOnUtcDay &&
          other.existingReportForRequestedGame ==
              existingReportForRequestedGame;

  @override
  int get hashCode => Object.hash(
    favoritePlayers,
    cloudDatabases,
    cloudSavedGames,
    gameReportsOnUtcDay,
    existingReportForRequestedGame,
  );
}

/// The last Premium verification the device holds, used ONLY while the live
/// entitlement cannot be fetched.
///
/// Bounded three ways: to [accountId] (another account on the same machine
/// inherits nothing), to [window] after [verifiedAt], and to [knownExpiry]
/// (a term that was due to end yesterday does not stretch because we went
/// offline). An authoritative online inactive result is recorded with
/// [wasActive] false and ends the grace immediately.
///
/// Offline access to PERSONAL documents is a separate matter and needs none
/// of this: owned documents and local files are free with or without any
/// verification.
@immutable
class DesktopOfflineVerification {
  const DesktopOfflineVerification({
    this.accountId,
    this.verifiedAt,
    this.wasActive = false,
    this.knownExpiry,
    this.inBillingGracePeriod = false,
    this.window = desktopOfflineVerificationGrace,
  });

  /// No verification on record.
  static const DesktopOfflineVerification none = DesktopOfflineVerification();

  final String? accountId;
  final DateTime? verifiedAt;
  final bool wasActive;
  final DateTime? knownExpiry;

  /// Billing grace was in effect at verification; the term timestamp then no
  /// longer bounds access (it is already in the past by design).
  final bool inBillingGracePeriod;
  final Duration window;

  /// Whether this record grants Premium to [currentAccountId] at [now].
  bool grantsPremium({
    required String? currentAccountId,
    required DateTime now,
  }) {
    final at = verifiedAt;
    final bound = accountId;
    if (!wasActive || at == null || bound == null) return false;
    if (bound != currentAccountId) return false;
    final age = now.difference(at);
    // A clock that moved backwards is not a reason to lock a verified member
    // out; a clock that moved past the window is.
    if (age > window) return false;
    final expiry = knownExpiry;
    if (!inBillingGracePeriod && expiry != null && !expiry.isAfter(now)) {
      return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopOfflineVerification &&
          other.accountId == accountId &&
          other.verifiedAt == verifiedAt &&
          other.wasActive == wasActive &&
          other.knownExpiry == knownExpiry &&
          other.inBillingGracePeriod == inBillingGracePeriod &&
          other.window == window;

  @override
  int get hashCode => Object.hash(
    accountId,
    verifiedAt,
    wasActive,
    knownExpiry,
    inBillingGracePeriod,
    window,
  );
}

/// Account-bound facts the evaluator needs that `SubscriptionState` does not
/// carry: who the current identity is, which entitlement generation is
/// current, the measured usage, and the offline verification on record.
///
/// `SubscriptionState` answers "is Premium active?"; this answers "for whom,
/// as of when, and how much of the free tier is spent?".
@immutable
class DesktopEntitlementSnapshot {
  const DesktopEntitlementSnapshot({
    this.accountId,
    this.isAnonymous = false,
    this.generation = 0,
    this.usage = DesktopUsage.unknown,
    this.offline = DesktopOfflineVerification.none,
  }) : assert(generation >= 0);

  /// Signed out, nothing measured, nothing on record.
  static const DesktopEntitlementSnapshot guest = DesktopEntitlementSnapshot();

  /// Current account id, or null when signed out.
  final String? accountId;

  /// The current session is an anonymous (guest) Supabase user.
  final bool isAnonymous;

  /// Bumped on every account change. Results fetched under an older
  /// generation must not be published or acted on.
  final int generation;
  final DesktopUsage usage;
  final DesktopOfflineVerification offline;

  /// A real account that can hold a purchase. Guests (signed out or
  /// anonymous) still get the entire free tier.
  bool get hasPermanentAccount => accountId != null && !isAnonymous;

  /// Whether the offline verification on record grants Premium right now.
  bool offlineGrantsPremium(DateTime now) =>
      offline.grantsPremium(currentAccountId: accountId, now: now);

  /// Whether [context] was built against this snapshot's identity. Contexts
  /// that do not assert a generation are never considered stale.
  bool isCurrentFor(DesktopAccessContext context) {
    if (context.entitlementGeneration == desktopUnassertedGeneration) {
      return true;
    }
    return context.entitlementGeneration == generation &&
        context.accountId == accountId;
  }

  /// Stamps [context] with this snapshot's account and generation so a later
  /// re-evaluation can detect a logout or account switch in between.
  DesktopAccessContext stamp(DesktopAccessContext context) => context.copyWith(
    accountId: accountId,
    clearAccountId: accountId == null,
    entitlementGeneration: generation,
  );

  DesktopEntitlementSnapshot withUsage(DesktopUsage usage) => copyWith(
    usage: usage,
  );

  DesktopEntitlementSnapshot copyWith({
    String? accountId,
    bool clearAccountId = false,
    bool? isAnonymous,
    int? generation,
    DesktopUsage? usage,
    DesktopOfflineVerification? offline,
  }) {
    return DesktopEntitlementSnapshot(
      accountId: clearAccountId ? null : accountId ?? this.accountId,
      isAnonymous: isAnonymous ?? this.isAnonymous,
      generation: generation ?? this.generation,
      usage: usage ?? this.usage,
      offline: offline ?? this.offline,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopEntitlementSnapshot &&
          other.accountId == accountId &&
          other.isAnonymous == isAnonymous &&
          other.generation == generation &&
          other.usage == usage &&
          other.offline == offline;

  @override
  int get hashCode =>
      Object.hash(accountId, isAnonymous, generation, usage, offline);
}
