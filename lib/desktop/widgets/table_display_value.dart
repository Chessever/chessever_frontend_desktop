/// Returns a desktop table value only when it carries meaningful information.
///
/// This is a presentation-boundary rule. Stored PGN/database metadata is not
/// changed; parser and storage sentinels are simply not painted as data.
String desktopTableDisplayValue(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return '';
  final lower = value.toLowerCase();
  if (RegExp(r'^\?+$').hasMatch(value) ||
      const <String>{
        '-',
        '--',
        '–',
        '—',
        'unknown',
        'unknown event',
        'unknown opening',
        'event',
        'n/a',
        'na',
        'null',
      }.contains(lower)) {
    return '';
  }
  return value;
}

/// Applies the shared table rule plus PGN's generic side-name sentinels.
String desktopTablePlayerValue(Object? raw) {
  final value = desktopTableDisplayValue(raw);
  if (const <String>{'white', 'black'}.contains(value.toLowerCase())) return '';
  return value;
}
