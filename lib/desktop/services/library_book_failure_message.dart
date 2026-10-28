/// Safe author-facing copy for snapshot/validation failures. Named empty,
/// metadata, permission and availability errors retain their transport mapping.
String? libraryBookSnapshotFailureMessage(Object? details, int? status) {
  final code = details is Map ? details['code'] : null;
  if (code == 'invalid_collection_games') {
    final games = details is Map ? details['games'] : null;
    final first = games is List && games.isNotEmpty ? games.first : null;
    final label = first is Map ? first['label'] : null;
    final reason = first is Map ? first['reason'] : null;
    if (label is String &&
        reason is String &&
        label.trim().isNotEmpty &&
        reason.trim().isNotEmpty &&
        label.length <= 160 &&
        reason.length <= 160 &&
        !RegExp(r'[\r\n\x00-\x1f]').hasMatch('$label$reason')) {
      return 'Could not prepare ${label.trim()}: ${reason.trim()} '
          'Your existing collection is unchanged.';
    }
    return 'One or more games could not be prepared for publishing. '
        'Your existing collection is unchanged.';
  }
  if (code == 'empty_collection' || code == 'forbidden_field') return null;
  if (status == 400 || status == 422) {
    return 'Could not prepare this collection for publishing. '
        'Check the details or retry. Your existing collection is unchanged.';
  }
  return null;
}
