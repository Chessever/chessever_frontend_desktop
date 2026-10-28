/// Private inserted-game credit directives. Parse only this known directive;
/// clocks, evaluations, drawings and human commentary remain independent.
final pgnSourceCreditDirective = RegExp(
  r'\[%src\s+([^\]]+)\]',
  caseSensitive: false,
);

List<String> sourceCreditDirectives(Iterable<String>? comments) => [
  for (final comment in comments ?? const <String>[])
    for (final match in pgnSourceCreditDirective.allMatches(comment))
      if (match.group(1)!.trim().isNotEmpty) match.group(0)!,
];

final _insertedPliesField = RegExp(r'(^|\|)plies=(\d+)(?=\||$)');

/// The number of inserted plies, when a structured credit proves its span.
int? insertedSourceCreditPlies(String directive) {
  final label = pgnSourceCreditDirective.firstMatch(directive)?.group(1);
  if (label == null) return null;
  final match = _insertedPliesField.firstMatch(label);
  final count = int.tryParse(match?.group(2) ?? '');
  return count != null && count > 0 ? count : null;
}

/// [directive] with its proven inserted span rewritten to [plies]; every
/// other field stays as written.
String withInsertedSourceCreditPlies(String directive, int plies) =>
    directive.replaceFirstMapped(pgnSourceCreditDirective, (match) {
      final label = match.group(1)!;
      final rewritten = label.replaceFirstMapped(
        _insertedPliesField,
        (field) => '${field.group(1)}plies=$plies',
      );
      return match.group(0)!.replaceFirst(label, rewritten);
    });

/// Shared readable credit for inline notation and foreign PGN. Legacy labels
/// stay intact; decode only the known structured vocabulary.
String sourceCreditText(String label) {
  final fields = <String, String>{};
  for (final part in label.split('|')) {
    final equals = part.indexOf('=');
    if (equals <= 0) continue;
    fields[part.substring(0, equals).trim()] =
        part.substring(equals + 1).trim();
  }
  if (!fields.keys.any(
    {'white', 'black', 'event', 'site', 'result'}.contains,
  )) {
    return label.trim();
  }
  String? value(String key) {
    final text = fields[key];
    return text == null || text.isEmpty || text == '?' ? null : text;
  }

  String? player(String side) {
    final name = value(side);
    if (name == null) return null;
    final title = value('${side}Title');
    final elo = value('${side}Elo');
    return '${title == null ? '' : '$title '}$name${elo == null ? '' : ' ($elo)'}';
  }

  final result = switch (value('result')) {
    '1-0' => '1–0',
    '0-1' => '0–1',
    '1/2-1/2' => '½–½',
    _ => null,
  };
  final white = player('white');
  final black = player('black');
  final plies = int.tryParse(value('plies') ?? '');
  final event = value('event');
  final site = value('site');
  final round = value('round');
  final year = value('year');
  final venue = <String>[
    if (event != null) event,
    if (site != null && site != event) site,
    if (round != null) 'R$round',
    if (year != null) year,
  ];
  final parts = <String>[
    if (result != null) result,
    if (plies != null && plies > 0) '($plies)',
    if (white != null || black != null)
      [if (white != null) white, if (black != null) black].join(' – '),
    if (venue.isNotEmpty) venue.join(' · '),
  ];
  return parts.join(' ');
}

/// Only the external copy loses its private wrapper; native source metadata
/// remains available for editing, undo, save and reopening.
String externalSourceCreditComment(String comment) => comment.replaceAllMapped(
  pgnSourceCreditDirective,
  (match) => sourceCreditText(match.group(1)!),
);
