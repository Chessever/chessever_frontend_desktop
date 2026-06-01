import 'package:flutter/foundation.dart';

@immutable
class DesktopTierPricing {
  const DesktopTierPricing({
    required this.tier,
    required this.monthlyAmount,
    required this.annualAmount,
  });

  final int tier;
  final double monthlyAmount;
  final double annualAmount;

  double get annualMonthlyEquivalent => annualAmount / 12;
}

@immutable
class DesktopResolvedPricing {
  const DesktopResolvedPricing({
    required this.pricing,
    required this.currencyCode,
    required this.isRemote,
    this.countryCode,
  });

  final DesktopTierPricing pricing;
  final String currencyCode;
  final bool isRemote;
  final String? countryCode;
}

class DesktopPricing {
  const DesktopPricing._();

  static const int defaultTier = 1;

  static const Map<int, DesktopTierPricing> prices = {
    1: DesktopTierPricing(tier: 1, monthlyAmount: 10.99, annualAmount: 99.99),
    2: DesktopTierPricing(tier: 2, monthlyAmount: 8.99, annualAmount: 79.99),
    3: DesktopTierPricing(tier: 3, monthlyAmount: 4.49, annualAmount: 31.99),
  };

  // Mirrors web/src/lib/countryTiers.ts and public.country_tiers.
  static const Map<String, int> countryTiers = {
    // Tier 1
    'LU': 1,
    'CH': 1,
    'IE': 1,
    'SG': 1,
    'NO': 1,
    'IS': 1,
    'US': 1,
    'MO': 1,
    'QA': 1,
    'DK': 1,
    'NL': 1,
    'AU': 1,
    'SM': 1,
    'AT': 1,
    'SE': 1,
    'BE': 1,
    'DE': 1,
    'FI': 1,
    'CA': 1,
    'HK': 1,
    'IL': 1,
    'GB': 1,
    'AE': 1,
    'FR': 1,
    'NZ': 1,
    'MT': 1,
    'AD': 1,
    'IT': 1,
    'AW': 1,
    'CY': 1,
    'PR': 1,
    'KR': 1,
    'ES': 1,
    'BS': 1,
    'BN': 1,
    'SI': 1,
    'JP': 1,
    'TW': 1,
    'SA': 1,
    'EE': 1,
    'CZ': 1,
    'KW': 1,
    'PT': 1,
    'GY': 1,
    'LT': 1,
    'BH': 1,
    'SK': 1,
    'BB': 1,
    'HU': 1,
    'LV': 1,
    'GR': 1,
    'KN': 1,
    'HR': 1,
    'PL': 1,
    'UY': 1,
    'AG': 1,
    'SC': 1,
    'RO': 1,
    'TT': 1,
    'OM': 1,
    'PA': 1,
    'PW': 1,

    // Tier 2
    'CR': 2,
    'MV': 2,
    'BG': 2,
    'CL': 2,
    'TR': 2,
    'KZ': 2,
    'RU': 2,
    'LC': 2,
    'MY': 2,
    'ME': 2,
    'CN': 2,
    'TM': 2,
    'MX': 2,
    'RS': 2,
    'NR': 2,
    'MU': 2,
    'GD': 2,
    'DO': 2,
    'AR': 2,
    'VC': 2,
    'BR': 2,
    'AL': 2,
    'DM': 2,
    'GE': 2,
    'MK': 2,
    'GA': 2,
    'AM': 2,
    'BA': 2,
    'PE': 2,
    'BY': 2,
    'BZ': 2,
    'MD': 2,
    'BW': 2,
    'CO': 2,
    'GQ': 2,
    'JM': 2,
    'TH': 2,
    'TV': 2,
    'MN': 2,
    'SR': 2,
    'AZ': 2,
    'MH': 2,
    'EC': 2,
    'LY': 2,
    'GT': 2,
    'FJ': 2,
    'ZA': 2,
    'PY': 2,
    'IQ': 2,
    'SV': 2,
    'UA': 2,
    'TO': 2,
    'CV': 2,
    'DZ': 2,
    'FM': 2,
    'WS': 2,
    'IR': 2,
    'ID': 2,
    'VN': 2,
    'JO': 2,
    'LB': 2,
    'NA': 2,
    'SZ': 2,
    'BT': 2,
    'MA': 2,
    'PH': 2,
    'DJ': 2,
    'TN': 2,
    'VE': 2,
    'BO': 2,
    'ST': 2,
    'LK': 2,
    'HN': 2,
    'VU': 2,
    'UZ': 2,

    // Tier 3
    'PS': 3,
    'EG': 3,
    'NI': 3,
    'AO': 3,
    'KH': 3,
    'IN': 3,
    'CI': 3,
    'BD': 3,
    'KI': 3,
    'PG': 3,
    'CG': 3,
    'HT': 3,
    'KG': 3,
    'MR': 3,
    'SB': 3,
    'GH': 3,
    'KE': 3,
    'ZW': 3,
    'SN': 3,
    'CM': 3,
    'LA': 3,
    'GN': 3,
    'KM': 3,
    'BJ': 3,
    'TL': 3,
    'NP': 3,
    'ZM': 3,
    'TJ': 3,
    'UG': 3,
    'TZ': 3,
    'SY': 3,
    'PK': 3,
    'MM': 3,
    'GW': 3,
    'ET': 3,
    'LS': 3,
    'TG': 3,
    'GM': 3,
    'TD': 3,
    'RW': 3,
    'BF': 3,
    'ML': 3,
    'LR': 3,
    'SL': 3,
    'NG': 3,
    'SO': 3,
    'NE': 3,
    'CD': 3,
    'MZ': 3,
    'ER': 3,
    'SD': 3,
    'MG': 3,
    'CF': 3,
    'YE': 3,
    'MW': 3,
    'AF': 3,
    'SS': 3,
    'BI': 3,
  };

  static int tierForCountry(String? countryCode) {
    final normalized = countryCode?.trim().toUpperCase();
    if (normalized == null || normalized.isEmpty) return defaultTier;
    return countryTiers[normalized] ?? defaultTier;
  }

  static DesktopTierPricing priceForCountry(String? countryCode) {
    return priceForTier(tierForCountry(countryCode));
  }

  static DesktopResolvedPricing resolveForCountry(
    String? countryCode, {
    bool isRemote = false,
    String currencyCode = 'USD',
  }) {
    return DesktopResolvedPricing(
      pricing: priceForCountry(countryCode),
      countryCode: countryCode,
      currencyCode: currencyCode,
      isRemote: isRemote,
    );
  }

  static String? preferredCountryCode({
    String? selectedCountryCode,
    String? platformCountryCode,
    String? localizationsCountryCode,
  }) {
    final selected = selectedCountryCode?.trim();
    if (selected != null && selected.isNotEmpty) return selected;

    final platform = platformCountryCode?.trim();
    if (platform != null && platform.isNotEmpty) return platform;

    final localizations = localizationsCountryCode?.trim();
    if (localizations != null && localizations.isNotEmpty) {
      return localizations;
    }

    return null;
  }

  static DesktopTierPricing priceForTier(int tier) {
    return prices[tier] ?? prices[defaultTier]!;
  }

  static String formatUsd(double amount) {
    final decimals = amount % 1 == 0 ? 0 : 2;
    return '\$${amount.toStringAsFixed(decimals)}';
  }
}
