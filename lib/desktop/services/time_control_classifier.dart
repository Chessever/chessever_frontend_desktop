/// Broad chess time-control buckets used by local desktop statistics.
///
/// PGN `TimeControl` tags are stored in seconds (`300+2`, `40/7200:3600`),
/// while broadcast metadata often stores free-form minute text (`15+10`,
/// `G/25;+10`). Keep those parsing contexts separate so ratings are not mixed
/// across incompatible clocks.
String? classifyTimeControlCategory(
  Object? timeControl, {
  Object? event,
  Object? site,
}) {
  return classifyPgnTimeControlCategory(timeControl) ??
      inferTimeControlCategoryFromEvent(event, site);
}

String? classifyPgnTimeControlCategory(Object? value) {
  final raw = _clean(value);
  if (raw == null) return null;

  final canonical = _canonicalWordCategory(raw);
  if (canonical != null) return canonical;

  final firstStage = raw.split(':').first.trim();
  if (firstStage.isEmpty) return null;
  final baseSegment =
      firstStage.contains('/') ? firstStage.split('/').last.trim() : firstStage;
  final plusParts = baseSegment.split('+');
  if (plusParts.isEmpty) return null;

  final baseSeconds = double.tryParse(plusParts.first.trim());
  if (baseSeconds == null || baseSeconds <= 0) {
    return classifyFreeformTimeControlCategory(value);
  }

  final incrementSeconds =
      plusParts.length > 1 ? double.tryParse(plusParts[1].trim()) ?? 0 : 0;
  final safeIncrement = incrementSeconds > 0 ? incrementSeconds : 0;
  return _classifyEffectiveSeconds(baseSeconds + safeIncrement * 40);
}

String? classifyFreeformTimeControlCategory(Object? value) {
  final raw = _clean(value);
  if (raw == null) return null;

  final canonical = _canonicalWordCategory(raw);
  if (canonical != null) return canonical;

  final baseMinutes = _freeformBaseMinutes(raw);
  if (baseMinutes == null || baseMinutes <= 0) return null;
  return _classifyBaseMinutes(baseMinutes);
}

String? inferTimeControlCategoryFromEvent(Object? event, Object? site) {
  final rawEvent = _clean(event);
  final rawSite = _clean(site) ?? '';
  if (rawEvent == null) return _sourceDefaultCategory(rawSite);

  if (rawEvent.contains('checkmate covid rematch')) return 'blitz';
  if (rawEvent.contains('titled') && rawEvent.contains('tue')) {
    return 'blitz';
  }
  if (rawEvent.contains('titled arena')) return 'blitz';
  if (rawEvent.contains('speedchess') || rawEvent.contains('speed chess')) {
    return 'blitz';
  }
  if (rawEvent.contains('wscc')) return 'blitz';
  if (rawEvent.contains('bullet')) return 'blitz';
  if (rawEvent.contains('blitz')) return 'blitz';
  if (rawEvent.contains('armageddon')) return 'blitz';
  if (rawEvent.contains('online olym')) return 'rapid';
  if (rawEvent.startsWith('euro online')) return 'rapid';
  if (rawEvent.startsWith('world corporate')) return 'rapid';
  if (rawEvent.contains('rapid')) return 'rapid';
  if (rawEvent.contains('pro league')) return 'rapid';
  if (rawEvent.contains('gran canaria online')) return 'rapid';
  if (rawEvent.contains('online') && rawEvent.contains('women')) return 'rapid';

  final embeddedMinutes = _freeformBaseMinutes(rawEvent);
  if (embeddedMinutes != null) return _classifyBaseMinutes(embeddedMinutes);

  final isChessCom = rawSite.contains('chess.com');
  if (!isChessCom) return _sourceDefaultCategory(rawSite);

  if (rawEvent.startsWith('chess.com speed')) return 'blitz';
  if (rawEvent.contains('women') && rawEvent.contains('speed')) return 'blitz';
  if (rawEvent.contains('junior speed')) return 'blitz';
  if (rawEvent.contains('speed play-in') ||
      rawEvent.contains('speed play in')) {
    return 'blitz';
  }
  if (RegExp(r'(^|[^0-9])3-0([^0-9]|$)').hasMatch(rawEvent)) {
    return 'blitz';
  }
  if (rawEvent.startsWith('chess.com rcc')) return 'rapid';

  final rapidish =
      rawEvent.contains('play-in') ||
      rawEvent.contains('play in') ||
      rawEvent.contains('masters') ||
      rawEvent.contains('cup') ||
      rawEvent.contains('classic');
  final fast =
      rawEvent.contains('blitz') ||
      rawEvent.contains('bullet') ||
      rawEvent.contains('speed');
  return rapidish && !fast ? 'rapid' : _sourceDefaultCategory(rawSite);
}

/// ChessEver's player export is the FIDE/OTB database source. Those PGNs
/// frequently omit `TimeControl`, so provenance is the only reliable fallback
/// after the event-name heuristics above have ruled out rapid/blitz events.
String? _sourceDefaultCategory(String rawSite) =>
    rawSite.contains('chessever') ? 'classical' : null;

String? _clean(Object? value) {
  final raw = value?.toString().trim().toLowerCase();
  if (raw == null || raw.isEmpty || raw == '?' || raw == '-' || raw == '*') {
    return null;
  }
  return raw;
}

String? _canonicalWordCategory(String raw) {
  if (raw == 'b' || raw == 'timecontrol.blitz' || raw == 'time_control.blitz') {
    return 'blitz';
  }
  if (raw == 'r' || raw == 'timecontrol.rapid' || raw == 'time_control.rapid') {
    return 'rapid';
  }
  if (raw == 'c' ||
      raw == 'timecontrol.classical' ||
      raw == 'time_control.classical' ||
      raw == 'standard') {
    return 'classical';
  }

  if (RegExp(r'\b(classical|standard|classic)\b').hasMatch(raw)) {
    return 'classical';
  }
  if (RegExp(r'\brapid\b').hasMatch(raw)) return 'rapid';
  if (RegExp(r'\b(blitz|bullet)\b').hasMatch(raw)) return 'blitz';
  return null;
}

double? _freeformBaseMinutes(String raw) {
  final hourMatch = RegExp(r'\b(\d+)\s*h\s*(\d+)?').firstMatch(raw);
  if (hourMatch != null) {
    final hours = double.tryParse(hourMatch.group(1) ?? '');
    if (hours == null) return null;
    final minutes = double.tryParse(hourMatch.group(2) ?? '') ?? 0;
    return hours * 60 + minutes;
  }

  final patterns = <RegExp>[
    RegExp(r'\b\d+\s*x\s*(\d+(?:[.,]\d+)?)'),
    RegExp(r'\bg\s*/?\s*(\d+(?:[.,]\d+)?)'),
    RegExp(r"\b(\d+(?:[.,]\d+)?)\s*(?:min|m\b|'|\+)"),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(raw);
    if (match == null) continue;
    return double.tryParse((match.group(1) ?? '').replaceAll(',', '.'));
  }
  return null;
}

String _classifyBaseMinutes(double baseMinutes) {
  if (baseMinutes < 10) return 'blitz';
  if (baseMinutes < 60) return 'rapid';
  return 'classical';
}

String _classifyEffectiveSeconds(double effectiveSeconds) {
  if (effectiveSeconds <= 600) return 'blitz';
  if (effectiveSeconds <= 3600) return 'rapid';
  return 'classical';
}
