import 'package:flutter/foundation.dart' show immutable, setEquals;

/// Ordering for the My Likes destination. Applied by the server query, never
/// by re-sorting rows that are already on screen.
enum LikedGamesSort {
  likedNewest('Liked: newest'),
  likedOldest('Liked: oldest'),
  gameDateNewest('Game date: newest'),
  ratingHighest('Average rating'),
  whitePlayer('White player A-Z');

  const LikedGamesSort(this.label);

  final String label;
}

enum LikedGamesResultFilter {
  any('Any result'),
  whiteWins('White won'),
  blackWins('Black won'),
  draw('Draw');

  const LikedGamesResultFilter(this.label);

  final String label;
}

enum LikedGamesTimeControlFilter {
  any('Any speed'),
  classical('Classical'),
  rapid('Rapid'),
  blitz('Blitz');

  const LikedGamesTimeControlFilter(this.label);

  final String label;
}

/// Server-side query for the Likes collection: text search, tags, structured
/// filters and one sort. Every field maps to a PostgREST clause in
/// `LibraryRepository.getLikedAnalysesForView`.
@immutable
class LikedAnalysesQuery {
  const LikedAnalysesQuery({
    this.search = '',
    this.tags = const <String>{},
    this.result = LikedGamesResultFilter.any,
    this.timeControl = LikedGamesTimeControlFilter.any,
    this.sort = LikedGamesSort.likedNewest,
  });

  final String search;

  /// OR semantics: a like matches when it carries ANY selected tag.
  final Set<String> tags;
  final LikedGamesResultFilter result;
  final LikedGamesTimeControlFilter timeControl;
  final LikedGamesSort sort;

  /// A sort other than the default liked-at order. When set, the list reads
  /// as one ordered result instead of being regrouped by liked-at day.
  bool get hasExplicitSort => sort != LikedGamesSort.likedNewest;

  int get structuredFilterCount =>
      (result == LikedGamesResultFilter.any ? 0 : 1) +
      (timeControl == LikedGamesTimeControlFilter.any ? 0 : 1);

  bool get isNarrowed =>
      search.trim().isNotEmpty || tags.isNotEmpty || structuredFilterCount > 0;

  LikedAnalysesQuery copyWith({
    String? search,
    Set<String>? tags,
    LikedGamesResultFilter? result,
    LikedGamesTimeControlFilter? timeControl,
    LikedGamesSort? sort,
  }) {
    return LikedAnalysesQuery(
      search: search ?? this.search,
      tags: tags ?? this.tags,
      result: result ?? this.result,
      timeControl: timeControl ?? this.timeControl,
      sort: sort ?? this.sort,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LikedAnalysesQuery &&
          other.search == search &&
          setEquals(other.tags, tags) &&
          other.result == result &&
          other.timeControl == timeControl &&
          other.sort == sort;

  @override
  int get hashCode => Object.hash(
    search,
    Object.hashAllUnordered(tags),
    result,
    timeControl,
    sort,
  );
}
