import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long a resolved pricing country stays locked. Mirrors the website's
/// `PRICING_COUNTRY_COOKIE_MAX_AGE` (30 days): the first country the site sees
/// wins for a month so roaming or a VPN cannot flip prices mid-decision, and
/// the desktop does the same so both surfaces show the same tier.
const Duration pricingCountryLockTtl = Duration(days: 30);

/// A pricing country the desktop locked in, with the moment it was locked.
/// The website keeps this in a signed HttpOnly cookie; the desktop keeps it
/// in local preferences — it never leaves the device, so there is no
/// signature to verify, only an expiry to honor.
@immutable
class DesktopPricingCountryLock {
  const DesktopPricingCountryLock({
    required this.country,
    required this.lockedAt,
  });

  /// Normalized ISO 3166-1 alpha-2 country code (`TR`, `US`, ...).
  final String country;

  final DateTime lockedAt;

  bool isExpired(DateTime now) =>
      now.difference(lockedAt) >= pricingCountryLockTtl;
}

/// Normalizes a candidate country the way the website's proxies do:
/// uppercase 2-letter code, with Cloudflare's unknown (`XX`) and Tor (`T1`)
/// markers treated as "no country".
String? normalizePricingCountry(String? value) {
  final country = value?.trim().toUpperCase() ?? '';
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(country)) return null;
  if (country == 'XX' || country == 'T1') return null;
  return country;
}

/// Parses a stored lock value (`CC.<epochSeconds>`). Returns null for
/// anything malformed or expired — an unreadable lock is the same as no
/// lock, and resolution falls through to a fresh geo read.
@visibleForTesting
DesktopPricingCountryLock? parsePricingCountryLock(
  String? value, {
  DateTime? now,
}) {
  if (value == null || value.isEmpty) return null;
  final parts = value.split('.');
  if (parts.length != 2) return null;
  final country = normalizePricingCountry(parts[0]);
  final epochSeconds = int.tryParse(parts[1]);
  if (country == null || epochSeconds == null || epochSeconds <= 0) {
    return null;
  }
  final lock = DesktopPricingCountryLock(
    country: country,
    lockedAt: DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000),
  );
  if (lock.isExpired(now ?? DateTime.now())) return null;
  return lock;
}

@visibleForTesting
String formatPricingCountryLock(DesktopPricingCountryLock lock) {
  final epochSeconds = lock.lockedAt.millisecondsSinceEpoch ~/ 1000;
  return '${lock.country}.$epochSeconds';
}

/// Persists the pricing-country lock. Best effort throughout: preferences
/// are a cache, never load-bearing — every failure reads as "no lock".
class DesktopPricingCountryLockStore {
  const DesktopPricingCountryLockStore();

  static const String _key = 'desktop.pricing_country.v1';

  Future<DesktopPricingCountryLock?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return parsePricingCountryLock(prefs.getString(_key));
    } on Object {
      return null;
    }
  }

  Future<void> save(String country) async {
    final normalized = normalizePricingCountry(country);
    if (normalized == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        formatPricingCountryLock(
          DesktopPricingCountryLock(
            country: normalized,
            lockedAt: DateTime.now(),
          ),
        ),
      );
    } on Object {
      // A lock that cannot be written is simply not locked.
    }
  }
}
