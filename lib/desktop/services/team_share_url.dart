import 'package:chessever/desktop/services/desktop_share_actions.dart'
    show buildDesktopEventShareUrl;

/// Sentinels that gamebase/TWIC rows put in `tourId` when there is no real
/// broadcast identity. Never treat these as URL path segments.
const _kDisplayOnlyTourIds = {'gamebase', 'miniatures'};

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _lichessShortIdPattern = RegExp(r'^[A-Za-z0-9]{8}$');

/// A genuine URL slug: lowercase words joined by `-` or `_`. Capitals,
/// spaces or other punctuation mean the value is a written name.
final _slugPattern = RegExp(r'^[a-z0-9]+(?:[-_][a-z0-9]+)*$');

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// True when [id] is a real broadcast or group-broadcast identity, not a
/// written event name or an archive sentinel. Mirrors the phone rule.
bool isDesktopUrlBackedEventId(String? id) {
  final trimmed = _nonEmpty(id);
  if (trimmed == null) return false;
  if (_kDisplayOnlyTourIds.contains(trimmed.toLowerCase())) return false;
  if (RegExp(r'\s').hasMatch(trimmed)) return false;
  return _slugPattern.hasMatch(trimmed) ||
      _uuidPattern.hasMatch(trimmed) ||
      _lichessShortIdPattern.hasMatch(trimmed);
}

/// True when a tour pair is safe to put in `/broadcast/<slug>/<id>`.
bool isDesktopUrlBackedTourIdentity({String? tourId, String? tourSlug}) {
  final slug = _nonEmpty(tourSlug);
  if (slug == null || !_slugPattern.hasMatch(slug)) return false;
  return isDesktopUrlBackedEventId(tourId);
}

/// Canonical team scorecard link:
/// `https://chessever.com/broadcast/<slug>/<id>/team/<encoded team name>`.
///
/// Returns null for archive and display-only identities, so sharing falls
/// back to an image only instead of a dead link.
String? buildDesktopTeamEventShareUrl({
  required String teamName,
  String? canonicalEventId,
  String? eventName,
  String? tourId,
  String? tourSlug,
}) {
  final team = _nonEmpty(teamName);
  if (team == null) return null;

  String? resolvedTourId;
  String? resolvedTourSlug;
  if (isDesktopUrlBackedTourIdentity(tourId: tourId, tourSlug: tourSlug)) {
    resolvedTourId = _nonEmpty(tourId);
    resolvedTourSlug = _nonEmpty(tourSlug);
  }
  final eventId =
      isDesktopUrlBackedEventId(canonicalEventId)
          ? _nonEmpty(canonicalEventId)
          : resolvedTourId;
  if (eventId == null) return null;

  final base = buildDesktopEventShareUrl(
    id: eventId,
    title: _nonEmpty(eventName) ?? team,
    tourId: resolvedTourId,
    tourSlug: resolvedTourSlug,
  );
  return '$base/team/${Uri.encodeComponent(team)}';
}
