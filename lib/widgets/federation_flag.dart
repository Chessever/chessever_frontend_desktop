import 'package:chessever/utils/country_utils.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_country_flags/flutter_country_flags.dart' as fcf;

class FederationFlag extends StatelessWidget {
  const FederationFlag({
    super.key,
    required this.federation,
    this.width,
    this.height,
    this.borderRadius,
  });

  /// Federation value from APIs.
  /// Can be ISO2 ("US"), FIDE alpha-3 ("USA"), or a country name ("Norway").
  final String? federation;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  /// UK constituent countries that need special flag handling.
  /// Maps FIDE codes to flutter_country_flags Country enum.
  static const Map<String, fcf.Country> _ukSubdivisions = {
    'ENG': fcf.Country.england,
    'SCO': fcf.Country.scotland,
    'WLS': fcf.Country.wales,
  };

  @override
  Widget build(BuildContext context) {
    final raw = (federation ?? '').trim();
    final normalized = raw.toUpperCase();

    if (raw.isEmpty) {
      return _fideFallback();
    }

    final lowerRaw = raw.toLowerCase();

    // Lichess emits literal "FIDE" (or "FID"/"?") when PGN carries no real
    // federation. Render the FIDE logo as the fallback flag for those players.
    if (normalized == 'FID' || normalized == 'FIDE' || normalized == '?') {
      return _fideFallback();
    }

    // Handle UK subdivisions (England, Scotland, Wales) with their own flags.
    if (_ukSubdivisions.containsKey(normalized)) {
      return _ukSubdivisionFlag(context, normalized);
    }
    if (lowerRaw == 'england') return _ukSubdivisionFlag(context, 'ENG');
    if (lowerRaw == 'scotland') return _ukSubdivisionFlag(context, 'SCO');
    if (lowerRaw == 'wales') return _ukSubdivisionFlag(context, 'WLS');

    String? iso2;
    if (normalized.length == 2) {
      iso2 = normalized;
    } else if (normalized.length == 3) {
      iso2 = CountryUtils.toIso2Code(normalized);
    } else {
      // Country name (e.g. "Norway", "Austria") — use manual mapping first
      // (more reliable), then fall back to country_picker's name lookup.
      final manual = CountryUtils.countryNameToIso2(raw);
      iso2 = manual.isNotEmpty ? manual : CountryUtils.getCountryCode(raw);
    }

    if (iso2 == null || iso2.length != 2) {
      return _fideFallback();
    }

    final child = CountryFlag.fromCountryCode(
iso2,
  theme: ImageTheme(width: width,
      height: height,),
);

    final radius = borderRadius ?? BorderRadius.circular(3);
    return ClipRRect(borderRadius: radius, child: child);
  }

  Widget _ukSubdivisionFlag(BuildContext context, String fideCode) {
    final country = _ukSubdivisions[fideCode];
    if (country == null) return _empty();

    final radius = borderRadius ?? BorderRadius.circular(3);
    return ClipRRect(
      borderRadius: radius,
      child: fcf.FlutterCountryFlags(
        country: country,
        width: width,
        height: height,
      ),
    );
  }

  Widget _empty() => SizedBox(width: width, height: height);

  Widget _fideFallback() {
    final radius = borderRadius ?? BorderRadius.circular(3);
    return ClipRRect(
      borderRadius: radius,
      child: Image.asset(
        PngAsset.fideLogo,
        width: width,
        height: height,
        fit: BoxFit.contain,
      ),
    );
  }
}
