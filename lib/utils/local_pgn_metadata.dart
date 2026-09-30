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
/// Display name for one side of a local PGN header bag.
///
/// A real player name is returned unchanged; a missing or placeholder value
/// (`?`, `-`, empty) names the side instead, so a record whose players were
/// never known never paints a bare `?` — the wording a user reads as "this
/// entry is broken". Storage is untouched: this is a presentation helper, and
/// identity matching keeps reading the raw tag values.
String localPgnDisplayPlayerName(Map<String, dynamic> metadata, String side) {
  final value = metadata[side]?.toString().trim() ?? '';
  if (value.isNotEmpty && value != '?' && value != '-') return value;
  return '$side ?';
}

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
