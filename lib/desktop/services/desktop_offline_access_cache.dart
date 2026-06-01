import 'package:flutter/foundation.dart' show visibleForTesting;

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

  static Duration get defaultGracePeriod => _defaultGracePeriod;

  static Future<void> recordEntitlement({
    required bool isActive,
    DateTime? verifiedAt,
  }) async {
    final prefs = await SharedPreferencesService.instance.ensureInitialized();
    if (prefs == null) return;

    final at = verifiedAt ?? DateTime.now();
    await prefs.setBool(_isActiveKey, isActive);
    await prefs.setInt(_verifiedAtKey, at.millisecondsSinceEpoch);
  }

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
