/// The name to show for one side of a Gamebase game row.
///
/// Gamebase keeps each source's spelling of a player: TWIC writes
/// "Gukesh,D", a broadcast "Gukesh D (IND)". When a side carries a valid FIDE
/// id, the server may also send `whiteCanonicalName` / `blackCanonicalName`,
/// the FIDE spelling, so one player reads the same on every row. Rows from a
/// server without those fields, and local PGN rows, show the stored `white` /
/// `whiteName`. Sorting and filtering keep using the stored name.
String gamebaseRowPlayerName(
  Map<String, dynamic> row, {
  required bool isWhite,
}) {
  final canonical = gamebaseRowCanonicalPlayerName(row, isWhite: isWhite);
  if (canonical != null) return canonical;
  for (final key in isWhite ? _kWhiteNameKeys : _kBlackNameKeys) {
    final value = row[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return '';
}

/// The FIDE spelling the server sent for one side, or null when the row has
/// none (an older server, no FIDE id, or a name that failed its check).
String? gamebaseRowCanonicalPlayerName(
  Map<String, dynamic> row, {
  required bool isWhite,
}) {
  final value =
      row[isWhite ? 'whiteCanonicalName' : 'blackCanonicalName']
          ?.toString()
          .trim() ??
      '';
  return value.isEmpty ? null : value;
}

const List<String> _kWhiteNameKeys = <String>['white', 'whiteName'];

const List<String> _kBlackNameKeys = <String>['black', 'blackName'];
