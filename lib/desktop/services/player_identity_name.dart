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
///
/// Separators are stripped after the swap, so surrounding whitespace and an
/// empty family/given part cannot change the key. Skipping those trims keeps
/// [expression] (often a `json_extract`) to a few evaluations per row.
String playerIdentityNameSql(String expression) {
  final raw = "COALESCE($expression, '')";
  final comma = "INSTR($raw, ',')";
  final swapped = "SUBSTR($raw, $comma + 1) || SUBSTR($raw, 1, $comma - 1)";
  return 'CASE '
      "WHEN $raw LIKE '%,%' AND $raw NOT LIKE '%,%,%' "
      'THEN ${_strippedNameSql(swapped)} '
      "WHEN TRIM($raw, $_whitespaceSql) = '?' THEN '' "
      'ELSE ${_strippedNameSql(raw)} END';
}

const String _whitespaceSql =
    "' ' || CHAR(9) || CHAR(10) || CHAR(11) || CHAR(12) || CHAR(13) || "
    'CHAR(160)';

String _strippedNameSql(String expression) {
  var sql = 'LOWER($expression)';
  for (final token in const <String>[',', ' ', '_', '.', '-']) {
    sql = "REPLACE($sql, '$token', '')";
  }
  for (final character in const <int>[9, 10, 11, 12, 13, 160]) {
    sql = "REPLACE($sql, CHAR($character), '')";
  }
  return sql;
}
