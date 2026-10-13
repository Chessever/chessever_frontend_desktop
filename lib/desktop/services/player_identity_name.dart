/// Stable name key for the two explicit PGN naming conventions.
///
/// A single comma means `Family, Given`; otherwise preserve word order.
/// Do not sort tokens or use initials/fuzzy matching: names alone must never
/// override a conflicting positive FIDE ID at a caller's identity boundary.
String playerIdentityNameKey(String? value) {
  var name = value?.trim() ?? '';
  if (name.isEmpty || name == '?') return '';
  final comma = name.indexOf(',');
  if (comma > 0 && comma == name.lastIndexOf(',')) {
    final family = name.substring(0, comma).trim();
    final given = name.substring(comma + 1).trim();
    if (given.isNotEmpty && family.isNotEmpty) name = '$given $family';
  }
  return name.toLowerCase().replaceAll(RegExp(r'[\s,._-]+'), '');
}

/// SQLite equivalent of [playerIdentityNameKey], for existing query paths.
/// [expression] is project-owned SQL, never user input.
String playerIdentityNameSql(String expression) {
  const whitespace =
      "' ' || CHAR(9) || CHAR(10) || CHAR(11) || CHAR(12) || CHAR(13)";
  final name = "TRIM(COALESCE($expression, ''), $whitespace)";
  final comma = "INSTR($name, ',')";
  final family = 'TRIM(SUBSTR($name, 1, $comma - 1), $whitespace)';
  final given = 'TRIM(SUBSTR($name, $comma + 1), $whitespace)';
  var sql =
      "LOWER(CASE WHEN $comma > 0 "
      "AND INSTR(SUBSTR($name, $comma + 1), ',') = 0 "
      "AND $family <> '' AND $given <> '' "
      "THEN $given || ' ' || $family ELSE $name END)";
  for (final token in const <String>[',', ' ', '_', '.', '-']) {
    sql = "REPLACE($sql, '$token', '')";
  }
  for (final character in const <int>[9, 10, 11, 12, 13]) {
    sql = "REPLACE($sql, CHAR($character), '')";
  }
  return "CASE WHEN $name = '?' THEN '' ELSE $sql END";
}
