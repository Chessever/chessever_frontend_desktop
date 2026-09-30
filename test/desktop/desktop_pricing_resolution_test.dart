import 'package:chessever/desktop/services/billing/desktop_pricing_country_lock.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLockStore extends DesktopPricingCountryLockStore {
  _FakeLockStore({this.locked});

  DesktopPricingCountryLock? locked;
  final List<String> saved = [];

  @override
  Future<DesktopPricingCountryLock?> load() async => locked;

  @override
  Future<void> save(String country) async {
    saved.add(country);
    locked = DesktopPricingCountryLock(
      country: country,
      lockedAt: DateTime.now(),
    );
  }
}

DesktopPricingCountryLock _lock(String country, {DateTime? at}) {
  return DesktopPricingCountryLock(
    country: country,
    lockedAt: at ?? DateTime.now(),
  );
}

void main() {
  group('normalizePricingCountry', () {
    test('normalizes and rejects like the website proxies', () {
      expect(normalizePricingCountry('tr'), 'TR');
      expect(normalizePricingCountry(' us '), 'US');
      expect(normalizePricingCountry(null), isNull);
      expect(normalizePricingCountry(''), isNull);
      expect(normalizePricingCountry('USA'), isNull);
      expect(normalizePricingCountry('XX'), isNull);
      expect(normalizePricingCountry('T1'), isNull);
    });
  });

  group('parsePricingCountryLock', () {
    test('round-trips a fresh lock and rejects the rest', () {
      final now = DateTime.now();
      final fresh = formatPricingCountryLock(_lock('TR', at: now));
      expect(parsePricingCountryLock(fresh, now: now)?.country, 'TR');

      final expired = formatPricingCountryLock(
        _lock('TR', at: now.subtract(pricingCountryLockTtl)),
      );
      expect(parsePricingCountryLock(expired, now: now), isNull);

      expect(parsePricingCountryLock(null), isNull);
      expect(parsePricingCountryLock(''), isNull);
      expect(parsePricingCountryLock('TR'), isNull);
      expect(parsePricingCountryLock('TR.notanumber'), isNull);
      expect(parsePricingCountryLock('XX.9999999999'), isNull);
    });
  });

  group('parsePricingApiBody', () {
    test('parses the site API shape', () {
      final resolved =
          parsePricingApiBody({
            'country': 'TR',
            'tier': 2,
            'currency': 'USD',
            'monthlyAmount': 8.99,
            'annualAmount': 79.99,
          })!;
      expect(resolved.pricing.tier, 2);
      expect(resolved.pricing.monthlyAmount, 8.99);
      expect(resolved.pricing.annualAmount, 79.99);
      expect(resolved.countryCode, 'TR');
      expect(resolved.currencyCode, 'USD');
      expect(resolved.isRemote, isTrue);
    });

    test('rejects an unknown tier and falls back per amount', () {
      expect(parsePricingApiBody({'tier': 9}), isNull);
      expect(parsePricingApiBody({}), isNull);

      final partial = parsePricingApiBody({'tier': 3})!;
      expect(partial.pricing.tier, 3);
      expect(partial.pricing.monthlyAmount, 4.49);
      expect(partial.pricing.annualAmount, 31.99);
      expect(partial.countryCode, isNull);
      expect(partial.currencyCode, 'USD');
    });
  });

  group('parseTraceCountry', () {
    test('reads the first loc line', () {
      expect(parseTraceCountry('fl=1\nloc=TR\nip=1.2.3.4\n'), 'TR');
      expect(parseTraceCountry('loc=us\n'), 'US');
      expect(parseTraceCountry('fl=1\n'), isNull);
      expect(parseTraceCountry('loc=XX\n'), isNull);
      expect(parseTraceCountry(''), isNull);
    });
  });

  group('resolveDesktopPricing', () {
    test('a locked country wins without touching the network', () async {
      final store = _FakeLockStore(locked: _lock('TR'));
      final resolved = await resolveDesktopPricing(
        lockStore: store,
        fetchApiBody: () => throw StateError('must not be called'),
        fetchTraceBody: () => throw StateError('must not be called'),
      );
      expect(resolved.pricing.tier, 2);
      expect(resolved.countryCode, 'TR');
      expect(store.saved, isEmpty);
    });

    test('a fresh API country is locked in', () async {
      final store = _FakeLockStore();
      final resolved = await resolveDesktopPricing(
        lockStore: store,
        fetchApiBody: () async => {'tier': 3, 'country': 'IN'},
        fetchTraceBody: () => throw StateError('must not be called'),
      );
      expect(resolved.pricing.tier, 3);
      expect(resolved.countryCode, 'IN');
      expect(store.saved, ['IN']);
    });

    test('an API failure falls through to trace geo', () async {
      final store = _FakeLockStore();
      final resolved = await resolveDesktopPricing(
        lockStore: store,
        fetchApiBody: () => throw StateError('challenged'),
        fetchTraceBody: () async => 'loc=TR\n',
      );
      expect(resolved.pricing.tier, 2);
      expect(resolved.countryCode, 'TR');
      expect(store.saved, ['TR']);
    });

    test('garbage everywhere resolves the tier 1 default', () async {
      final store = _FakeLockStore();
      final resolved = await resolveDesktopPricing(
        lockStore: store,
        fetchApiBody: () async => {'tier': 'nonsense'},
        fetchTraceBody: () async => 'no location here',
      );
      expect(resolved.pricing.tier, 1);
      expect(resolved.pricing.monthlyAmount, 10.99);
      expect(resolved.countryCode, isNull);
      expect(store.saved, isEmpty);
    });

    test('an API tier without a country is used but not locked', () async {
      final store = _FakeLockStore();
      final resolved = await resolveDesktopPricing(
        lockStore: store,
        fetchApiBody: () async => {'tier': 2},
        fetchTraceBody: () => throw StateError('must not be called'),
      );
      expect(resolved.pricing.tier, 2);
      expect(store.saved, isEmpty);
    });
  });
}
