import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/repository/local_storage/country_man/country_man_repository.dart';

/// The player's own federation in Play: the country they chose for
/// Countrymen, as an uppercase ISO-3166 alpha-2 code. Shown as their flag
/// beside their name and written to the game's PGN (`WhiteFed` /
/// `BlackFed`).
///
/// Only a country the player actually saved counts. The Countrymen picker
/// falls back to the device's region (and to US once signed out) so it
/// always has something to show; none of those guesses is ever written
/// into a game as the player's federation.
final playUserCountryCodeAsyncProvider = FutureProvider<String?>((ref) async {
  final country = ref.watch(countryDropdownProvider).valueOrNull;
  if (country == null) return null;
  final saved = await ref.read(countryManRepository).getSavedCountryManLocal();
  if (saved == null || saved.trim().isEmpty) return null;
  final code = country.countryCode.trim().toUpperCase();
  return code.isEmpty ? null : code;
});

/// [playUserCountryCodeAsyncProvider] as a plain value: null while it loads
/// or when the player has not chosen a country.
final playUserCountryCodeProvider = Provider<String?>(
  (ref) => ref.watch(playUserCountryCodeAsyncProvider).valueOrNull,
);
