import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/repository/local_storage/local_storage_repository.dart';

/// Local grace-period record that lets desktop keep already-open/local features
/// available when the user loses internet.
///
/// The backend entitlement remains authoritative whenever the app is online.
/// This cache is only a bounded fallback: a previously verified premium user may
/// enter the desktop shell for [_defaultGracePeriod] while offline, so local
/// boards/files/cached games are not blocked by a network outage.
class DesktopOfflineAccessCache {
  DesktopOfflineAccessCache._();

  static const Duration _defaultGracePeriod = Duration(days: 14);
  static const String _verifiedAtKey = 'desktop_offline_access_verified_at_ms';
  static const String _isActiveKey = 'desktop_offline_access_is_active';
  static const String _accountIdKey = 'desktop_offline_access_account_id';
  static const String _expiresAtKey = 'desktop_offline_access_expires_at_ms';
  static const String _billingGraceKey =
      'desktop_offline_access_in_billing_grace';

  static Duration get defaultGracePeriod => _defaultGracePeriod;

  /// Records the outcome of an AUTHORITATIVE online entitlement check.
  ///
  /// An inactive result overwrites any earlier active one, which ends the
  /// Premium offline grace immediately. [accountId] and [expiresAt] bind the
  /// record: another account inherits nothing, and a term that was due to end
  /// is not extended by going offline.
  static Future<void> recordEntitlement({
    required bool isActive,
    String? accountId,
    DateTime? expiresAt,
    bool inBillingGracePeriod = false,
    DateTime? verifiedAt,
  }) async {
    final prefs = await SharedPreferencesService.instance.ensureInitialized();
    if (prefs == null) return;

    final at = verifiedAt ?? DateTime.now();
    await prefs.setBool(_isActiveKey, isActive);
    await prefs.setInt(_verifiedAtKey, at.millisecondsSinceEpoch);
    await prefs.setBool(_billingGraceKey, inBillingGracePeriod);
    if (accountId == null) {
      await prefs.remove(_accountIdKey);
    } else {
      await prefs.setString(_accountIdKey, accountId);
    }
    if (expiresAt == null) {
      await prefs.remove(_expiresAtKey);
    } else {
      await prefs.setInt(_expiresAtKey, expiresAt.millisecondsSinceEpoch);
    }
  }

  /// The account-bound Premium verification on record, for the offline grace
  /// applied by `evaluateDesktopAccess` and the desktop subscription notifier.
  ///
  /// A legacy record written before account binding carries no account id
  /// and therefore grants nothing; the next successful online check rewrites
  /// it with the account attached.
  static Future<DesktopOfflineVerification> readOfflineVerification() async {
    final prefs = await SharedPreferencesService.instance.ensureInitialized();
    if (prefs == null) return DesktopOfflineVerification.none;
    return offlineVerificationFromRecord(
      isActive: prefs.getBool(_isActiveKey) ?? false,
      verifiedAtMs: prefs.getInt(_verifiedAtKey),
      accountId: prefs.getString(_accountIdKey),
      expiresAtMs: prefs.getInt(_expiresAtKey),
      inBillingGracePeriod: prefs.getBool(_billingGraceKey) ?? false,
    );
  }

  @visibleForTesting
  static DesktopOfflineVerification offlineVerificationFromRecord({
    required bool isActive,
    required int? verifiedAtMs,
    required String? accountId,
    required int? expiresAtMs,
    bool inBillingGracePeriod = false,
    Duration gracePeriod = _defaultGracePeriod,
  }) {
    return DesktopOfflineVerification(
      accountId: accountId,
      wasActive: isActive,
      verifiedAt: verifiedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(verifiedAtMs),
      knownExpiry: expiresAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
      inBillingGracePeriod: inBillingGracePeriod,
      window: gracePeriod,
    );
  }

  /// Shell/session recovery probe used by the auth gate while offline.
  ///
  /// Not a Premium decision: Premium work consults the account-bound
  /// [readOfflineVerification] instead.
  static Future<bool> canUseOfflineAccess({
    DateTime? now,
    Duration gracePeriod = _defaultGracePeriod,
  }) async {
    final prefs = await SharedPreferencesService.instance.ensureInitialized();
    if (prefs == null) return false;

    final isActive = prefs.getBool(_isActiveKey) ?? false;
    final verifiedAtMs = prefs.getInt(_verifiedAtKey);
    return isOfflineAccessAllowed(
      isActive: isActive,
      verifiedAtMs: verifiedAtMs,
      now: now ?? DateTime.now(),
      gracePeriod: gracePeriod,
    );
  }

  static Future<DateTime?> lastVerifiedAt() async {
    final prefs = await SharedPreferencesService.instance.ensureInitialized();
    final ms = prefs?.getInt(_verifiedAtKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @visibleForTesting
  static bool isOfflineAccessAllowed({
    required bool isActive,
    required int? verifiedAtMs,
    required DateTime now,
    Duration gracePeriod = _defaultGracePeriod,
  }) {
    if (!isActive || verifiedAtMs == null) return false;
    final verifiedAt = DateTime.fromMillisecondsSinceEpoch(verifiedAtMs);
    final age = now.difference(verifiedAt);
    if (age.isNegative) return true;
    return age <= gracePeriod;
  }
}
