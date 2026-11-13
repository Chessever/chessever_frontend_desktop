import 'combined_section_labels.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/desktop/combined/combined_source_policy.dart';
import 'package:flutter/foundation.dart';

export 'package:chessever/desktop/combined/combined_source_policy.dart';

const String kCombinedCategoryLabel = 'Combined';

/// One real category merged into Combined.
@immutable
class CombinedCategory {
  const CombinedCategory({
    required this.tourId,
    required this.label,
    required this.avgElo,
    required this.order,
    this.startsAt,
    this.sourceName,
  });

  final String tourId;

  /// The category as the picker names it ("Group A").
  final String label;

  /// Full source title, retained for web-compatible knockout stage ranking.
  final String? sourceName;
  final int? avgElo;

  /// Position in the picker, used as the last ordering tie-break.
  final int order;

  /// When the category begins. Between two equally rated categories the one
  /// that starts later reads first.
  final DateTime? startsAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CombinedCategory &&
          other.tourId == tourId &&
          other.label == label &&
          other.sourceName == sourceName &&
          other.avgElo == avgElo &&
          other.order == order &&
          other.startsAt == startsAt;

  @override
  int get hashCode =>
      Object.hash(tourId, label, sourceName, avgElo, order, startsAt);
}

/// The categories Combined merges for one event. Value-equal, so a metadata
/// refresh that changes nothing here does not rebuild the combined list.
@immutable
class CombinedCategories {
  const CombinedCategories(this.items);

  static const none = CombinedCategories(<CombinedCategory>[]);

  /// Picks the real categories out of [tours].
  ///
  /// An organizer's own Combined section is left out: it mirrors the others,
  /// so merging it would list every board twice. It is recognised by the
  /// database's mirror flag or by its name. A mirror nobody flagged or named
  /// is still caught later, from its boards (see `findMirrorTourIds`).
  factory CombinedCategories.fromTours(
    List<TourModel> tours, {
    String? groupName,
  }) {
    final real = [
      for (final model in tours)
        if (isCombinedSourceTour(model.tour)) model,
    ];
    final seen = <String>{};
    final source = real.where((model) => seen.add(model.tour.id)).toList();
    final labels = combinedSwitcherLabels([
      for (final model in source) model.tour.name,
    ], groupName: groupName);
    return CombinedCategories(
      List<CombinedCategory>.unmodifiable([
        for (var i = 0; i < source.length; i++)
          CombinedCategory(
            tourId: source[i].tour.id,
            sourceName: source[i].tour.name,
            label: labels[i],
            avgElo: source[i].tour.avgElo,
            order: i,
            startsAt:
                source[i].tour.dates.isEmpty
                    ? null
                    : source[i].tour.dates.first,
          ),
      ]),
    );
  }

  final List<CombinedCategory> items;

  /// Combined only means something with at least two categories to merge.
  bool get canCombine => items.length >= 2;

  List<String> get tourIds => [for (final item in items) item.tourId];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CombinedCategories && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}

/// A generated event rail spans several real tours, whose order must survive
/// board opens and refreshes rather than being replaced by one source tour.
bool hasCombinedTournamentSources(Iterable<String> tourIds) {
  String? first;
  for (final raw in tourIds) {
    final id = raw.trim();
    if (id.isEmpty) continue;
    first ??= id;
    if (first != id) return true;
  }
  return false;
}
