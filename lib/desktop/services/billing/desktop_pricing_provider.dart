import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

import 'desktop_pricing.dart';

final desktopPricingProvider = FutureProvider<DesktopResolvedPricing>((
  ref,
) async {
  final fallbackCountry = ui.PlatformDispatcher.instance.locale.countryCode;

  try {
    return await _fetchWebPricing().timeout(const Duration(seconds: 5));
  } catch (_) {
    try {
      return await _fetchRenderedWebPricing().timeout(
        const Duration(seconds: 5),
      );
    } catch (_) {
      try {
        final countryCode = await _fetchNetworkCountryCode().timeout(
          const Duration(seconds: 3),
        );
        return DesktopPricing.resolveForCountry(countryCode, isRemote: true);
      } catch (_) {
        return DesktopPricing.resolveForCountry(fallbackCountry);
      }
    }
  }
});

Future<DesktopResolvedPricing> _fetchWebPricing() async {
  final response = await http.get(
    Uri.https('chessever.com', '/api/pricing'),
    headers: const {'accept': 'application/json'},
  );

  if (response.statusCode != 200) {
    throw StateError('pricing endpoint returned ${response.statusCode}');
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final tier = body['tier'] as int?;
  if (tier == null || !DesktopPricing.prices.containsKey(tier)) {
    throw StateError('pricing endpoint returned an invalid tier');
  }

  final local = DesktopPricing.priceForTier(tier);
  final monthlyAmount = (body['monthlyAmount'] as num?)?.toDouble();
  final annualAmount = (body['annualAmount'] as num?)?.toDouble();
  final countryCode = (body['country'] as String?)?.trim();
  final currencyCode = (body['currency'] as String?)?.trim().toUpperCase();

  return DesktopResolvedPricing(
    pricing: DesktopTierPricing(
      tier: tier,
      monthlyAmount: monthlyAmount ?? local.monthlyAmount,
      annualAmount: annualAmount ?? local.annualAmount,
    ),
    countryCode:
        countryCode == null || countryCode.isEmpty ? null : countryCode,
    currencyCode:
        currencyCode == null || currencyCode.isEmpty ? 'USD' : currencyCode,
    isRemote: true,
  );
}

Future<DesktopResolvedPricing> _fetchRenderedWebPricing() async {
  final response = await http.get(
    Uri.https('chessever.com', '/pricing'),
    headers: const {'accept': 'text/html'},
  );
  if (response.statusCode != 200) {
    throw StateError('pricing page returned ${response.statusCode}');
  }

  for (final pricing in DesktopPricing.prices.values) {
    if (response.body.contains(
      DesktopPricing.formatUsd(pricing.annualAmount),
    )) {
      return DesktopResolvedPricing(
        pricing: pricing,
        currencyCode: 'USD',
        countryCode: null,
        isRemote: true,
      );
    }
  }

  throw StateError('pricing page did not include a known annual amount');
}

Future<String> _fetchNetworkCountryCode() async {
  final response = await http.get(
    Uri.https('www.cloudflare.com', '/cdn-cgi/trace'),
    headers: const {'accept': 'text/plain'},
  );
  if (response.statusCode != 200) {
    throw StateError('country lookup returned ${response.statusCode}');
  }

  for (final line in const LineSplitter().convert(response.body)) {
    if (!line.startsWith('loc=')) continue;
    final countryCode = line.substring(4).trim().toUpperCase();
    if (countryCode.length == 2) return countryCode;
  }

  throw StateError('country lookup did not include loc');
}
