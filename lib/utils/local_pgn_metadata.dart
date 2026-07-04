/// Helpers for reading player fields out of a local PGN header bag.
///
/// Local imports keep every PGN tag verbatim, but the tag names for
/// federation vary by exporter and TWIC-style exports omit titles and
/// countries entirely, so all readers must share the same probing rules.
library;

/// Resolves the federation for one side ('White'/'Black') from a local PGN
/// header bag. PGN has no standard country tag, so probe the suffixes seen in
/// the wild.
String localPgnFederation(Map<String, dynamic> metadata, String side) {
  for (final suffix in const <String>[
    'Federation',
    'Fed',
    'Country',
    'TeamCountry',
    'Flag',
  ]) {
    final value = metadata['$side$suffix']?.toString().trim() ?? '';
    if (value.isNotEmpty && value != '?' && value != '-') return value;
  }
  return '';
}

/// Title tag for one side, with placeholder values treated as absent.
String localPgnTitle(Map<String, dynamic> metadata, String side) {
  final value = metadata['${side}Title']?.toString().trim() ?? '';
  if (value == '?' || value == '-') return '';
  return value;
}

/// FIDE ID tag for one side, or null when missing/invalid.
int? localPgnFideId(Map<String, dynamic> metadata, String side) {
  final id = int.tryParse(metadata['${side}FideId']?.toString().trim() ?? '');
  return id != null && id > 0 ? id : null;
}
