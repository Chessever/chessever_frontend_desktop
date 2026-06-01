import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:country_picker/country_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('effectiveCountryProvider reactivity', () {
    test('reflects temp country immediately on change', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final tr = CountryService().findByCode('TR')!;
      final fr = CountryService().findByCode('FR')!;

      // Prime effective provider so it subscribes to temp + persisted.
      container.read(effectiveCountryProvider);

      container.read(temporaryCountryProvider.notifier).state = tr;
      expect(
        container.read(effectiveCountryProvider).valueOrNull?.countryCode,
        'TR',
      );

      container.read(temporaryCountryProvider.notifier).state = fr;
      expect(
        container.read(effectiveCountryProvider).valueOrNull?.countryCode,
        'FR',
      );
    });

    test('null temp defers to persisted state shape', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(temporaryCountryProvider), isNull);
      final effective = container.read(effectiveCountryProvider);
      final persisted = container.read(countryDropdownProvider);
      // When temp is null, effectiveCountryProvider just forwards
      // countryDropdownProvider's current AsyncValue. Both should match.
      expect(effective.valueOrNull?.countryCode,
          persisted.valueOrNull?.countryCode);
      expect(effective.isLoading, persisted.isLoading);
    });
  });
}
