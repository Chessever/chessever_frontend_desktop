import 'package:flutter/foundation.dart';

final RegExp _roundPairingEventPattern = RegExp(
  r'^\s*round\s+\d+\s*:',
  caseSensitive: false,
);

final RegExp _lichessBroadcastSlugPattern = RegExp(
  r'lichess\.org/broadcast/([^/?#]+)/',
  caseSensitive: false,
);

final RegExp _yearPattern = RegExp(r'\b(19|20)\d{2}\b');

bool isTwicRoundPairingEventTitle(String title) {
  return _roundPairingEventPattern.hasMatch(title.trim());
}

@visibleForTesting
String? twicBroadcastParentSlugFromSite(String? site) {
  final value = site?.trim();
  if (value == null || value.isEmpty) return null;
  final match = _lichessBroadcastSlugPattern.firstMatch(value);
  final slug = match?.group(1)?.trim();
  return (slug == null || slug.isEmpty) ? null : slug;
}

@visibleForTesting
String? twicEventTitleFromBroadcastSite(String? site) {
  final slug = twicBroadcastParentSlugFromSite(site);
  if (slug == null) return null;
  return slug
      .split(RegExp(r'[-_]+'))
      .where((part) => part.trim().isNotEmpty)
      .map(_titleWord)
      .join(' ');
}

String _titleWord(String raw) {
  final word = raw.trim();
  if (word.isEmpty) return word;
  if (RegExp(r'^\d+(st|nd|rd|th)$', caseSensitive: false).hasMatch(word)) {
    return word.toLowerCase();
  }
  if (_yearPattern.hasMatch(word)) return word;
  return word[0].toUpperCase() + word.substring(1).toLowerCase();
}

String twicCanonicalEventKey(String title) {
  final withoutYear = title.toLowerCase().replaceAll(_yearPattern, ' ');
  final withoutNoise = withoutYear
      .replaceAll(RegExp(r'\bannual\b'), ' ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  return withoutNoise;
}

String preferredTwicEventTitle({required String event, String? site}) {
  final raw = event.trim();
  if (!isTwicRoundPairingEventTitle(raw)) {
    return raw.isNotEmpty ? raw : 'Gamebase';
  }

  final fromSite = twicEventTitleFromBroadcastSite(site);
  if (fromSite != null && fromSite.trim().isNotEmpty) {
    return fromSite.trim();
  }

  return raw.isNotEmpty ? raw : 'Gamebase';
}
