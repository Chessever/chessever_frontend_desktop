import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

import 'desktop_pricing.dart';
import 'desktop_pricing_country_lock.dart';

/// Pricing as chessever.com/pricing shows it, resolved the way the site
/// resolves it: a locked country first (the desktop equivalent of the site's
/// 30-day pricing cookie), then a fresh geo read, then the tier 1 default
/// the site uses when the country is unknown.
///
/// Deliberately NOT in the chain: the device locale (an en_US Mac in Turkey
/// is not a US customer — locale is what made the desktop disagree with the
/// site) and scraping the rendered pricing page (same host as the API, so it
/// fails exactly when the API fails, and it matches the wrong tier the
/// moment any page copy mentions another tier's annual).
final desktopPricingProvider = FutureProvider<DesktopResolvedPricing>((
  ref,
) async {
  return resolveDesktopPricing();
});

/// Test seam: the decoded `/api/pricing` JSON body.
typedef PricingApiFetch = Future<Map<String, dynamic>> Function();

/// Test seam: the raw `cdn-cgi/trace` response body.
typedef TraceFetch = Future<String> Function();

@visibleForTesting
Future<DesktopResolvedPricing> resolveDesktopPricing({
  DesktopPricingCountryLockStore lockStore =
      const DesktopPricingCountryLockStore(),
  PricingApiFetch? fetchApiBody,
  TraceFetch? fetchTraceBody,
}) async {
  final locked = await lockStore.load();
  if (locked != null) {
    return DesktopPricing.resolveForCountry(locked.country, isRemote: true);
  }

  try {
    final body = await (fetchApiBody ?? _fetchPricingApiBody)().timeout(
      const Duration(seconds: 5),
    );
    final resolved = parsePricingApiBody(body);
    if (resolved != null) {
      final country = resolved.countryCode;
      if (country != null) await lockStore.save(country);
      return resolved;
    }
  } on Object {
    // Cloudflare challenges non-browser clients, VPNs stall, hotel wifi
    // lies: any failure falls through to network geo.
  }

  try {
    final trace = await (fetchTraceBody ?? _fetchTraceBody)().timeout(
      const Duration(seconds: 3),
    );
    final country = parseTraceCountry(trace);
    if (country != null) {
      await lockStore.save(country);
      return DesktopPricing.resolveForCountry(country, isRemote: true);
    }
  } on Object {
    // Fall through to the default tier.
  }

  return DesktopPricing.resolveForCountry(null);
}

/// Parses a decoded `/api/pricing` body. Null when the tier is missing or
/// unknown — a 200 with garbage must fall through to geo, not Tier 1.
/// Amounts fall back to the local table per field, so a partial body still
/// shows the server's tier at known prices.
@visibleForTesting
DesktopResolvedPricing? parsePricingApiBody(Map<String, dynamic> body) {
  final tier = body['tier'] as int?;
  if (tier == null || !DesktopPricing.prices.containsKey(tier)) return null;

  final local = DesktopPricing.priceForTier(tier);
  final monthlyAmount = (body['monthlyAmount'] as num?)?.toDouble();
  final annualAmount = (body['annualAmount'] as num?)?.toDouble();
  final countryCode = normalizePricingCountry(body['country'] as String?);
  final currencyCode =
      (body['currency'] as String?)?.trim().toUpperCase() ?? '';

  return DesktopResolvedPricing(
    pricing: DesktopTierPricing(
      tier: tier,
      monthlyAmount: monthlyAmount ?? local.monthlyAmount,
      annualAmount: annualAmount ?? local.annualAmount,
    ),
    countryCode: countryCode,
    currencyCode: currencyCode.isEmpty ? 'USD' : currencyCode,
    isRemote: true,
  );
}

/// First `loc=` line of a Cloudflare trace response, normalized. Null when
/// the trace carries no usable country.
@visibleForTesting
String? parseTraceCountry(String traceBody) {
  for (final line in const LineSplitter().convert(traceBody)) {
    if (!line.startsWith('loc=')) continue;
    return normalizePricingCountry(line.substring(4));
  }
  return null;
}

Future<Map<String, dynamic>> _fetchPricingApiBody() async {
  final response = await http.get(
    Uri.https('chessever.com', '/api/pricing'),
    headers: const {'accept': 'application/json'},
  );

  if (response.statusCode != 200) {
    throw StateError('pricing endpoint returned ${response.statusCode}');
  }

  return jsonDecode(response.body) as Map<String, dynamic>;
}

Future<String> _fetchTraceBody() async {
  final response = await http.get(
    Uri.https('www.cloudflare.com', '/cdn-cgi/trace'),
    headers: const {'accept': 'text/plain'},
  );
  if (response.statusCode != 200) {
    throw StateError('country lookup returned ${response.statusCode}');
  }
  return response.body;
}
