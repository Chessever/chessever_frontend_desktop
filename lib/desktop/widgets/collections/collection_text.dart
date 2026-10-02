/// The words Collections uses for a collection, the same ones the phone app
/// prints, kept in one place so the catalog, the preview and the opened
/// collection never say it three ways.
library;

import 'package:chessever/repository/gamebase/collections/collections_models.dart';

/// "1 game" / "24 games".
String collectionGamesLabel(int count) =>
    count == 1 ? '1 game' : '$count games';

/// Who a collection is by: its author, else whoever annotated it.
String? collectionCredit(Collection collection) {
  for (final name in [collection.author, collection.annotator]) {
    final text = name?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return null;
}

/// The line a catalog row adds after the title: the team's note for it, or
/// the events it is bound to.
String? collectionCaption(Collection collection) {
  final note = collection.note?.trim() ?? '';
  if (note.isNotEmpty) return note;
  final titles = [
    for (final event in collection.events)
      if (event.title.trim().isNotEmpty) event.title.trim(),
  ];
  if (titles.isNotEmpty) {
    return titles.length == 1
        ? titles.first
        : '${titles.first} and ${titles.length - 1} more';
  }
  if (collection.eventCount > 0) {
    return collection.eventCount == 1
        ? '1 event'
        : '${collection.eventCount} events';
  }
  final subtitle = collection.subtitle?.trim() ?? '';
  return subtitle.isEmpty ? null : subtitle;
}

/// The short name of what a collection is, for its badge.
String collectionKindLabel(CollectionKind kind) => switch (kind) {
  CollectionKind.book => 'Collection',
  CollectionKind.event => 'Event collection',
  CollectionKind.analysis => 'Analysis',
};

/// What the unlock button of a locked collection says.
String collectionUnlockLabel(Collection collection) {
  final count = collection.gameCount;
  if (collection.kind == CollectionKind.book) {
    if (count <= 0) return 'Read this collection';
    if (count == 1) return 'Read the game in this collection';
    return 'Read all $count games in this collection';
  }
  if (count <= 0) return 'Replay these games';
  if (count == 1) return 'Replay the game';
  return 'Replay all $count games';
}

/// "Simon & Schuster · 1969", or whichever of the two is known.
String? collectionEdition(Collection collection) {
  final parts = [
    if (collection.publisher?.trim().isNotEmpty ?? false)
      collection.publisher!.trim(),
    if (collection.publishedYear != null) '${collection.publishedYear}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Oct 2, 2025", "Oct 2-14, 2025" or "Sep 28 - Oct 3, 2025".
String? collectionDateRange(DateTime? start, DateTime? end) {
  final from = start ?? end;
  if (from == null) return null;
  final to = end ?? start!;
  String day(DateTime d) => '${_months[d.month - 1]} ${d.day}';
  if (from.year == to.year && from.month == to.month && from.day == to.day) {
    return '${day(from)}, ${from.year}';
  }
  if (from.year == to.year && from.month == to.month) {
    return '${day(from)}-${to.day}, ${from.year}';
  }
  if (from.year == to.year) return '${day(from)} - ${day(to)}, ${to.year}';
  return '${day(from)}, ${from.year} - ${day(to)}, ${to.year}';
}

/// The one-line facts under an opened collection's title.
String collectionFactsLine(Collection collection) {
  final credit = collectionCredit(collection);
  final edition = collectionEdition(collection);
  final where = [
    if (collection.location?.trim().isNotEmpty ?? false)
      collection.location!.trim(),
    if (collectionDateRange(collection.dateStart, collection.dateEnd)
        case final dates?)
      dates,
  ];
  return [
    if (credit != null) 'by $credit',
    collectionGamesLabel(collection.gameCount),
    if (collection.kind == CollectionKind.book && edition != null) edition,
    if (collection.kind != CollectionKind.book) ...where,
  ].join(' · ');
}

/// Paragraphs of a prose field: split on blank lines, as the phone does.
List<String> collectionParagraphs(String? text) => [
  for (final part in (text ?? '').split(RegExp(r'\n\s*\n')))
    if (part.trim().isNotEmpty) part.trim(),
];
