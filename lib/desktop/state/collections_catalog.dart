/// Paged reads of the published collections catalog and its authors.
///
/// One notifier per query: a new search is a new provider, so a reply to an
/// older search can never land in the list a newer one is showing.
library;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/collections_reader.dart';

/// A page-by-page list as the catalog shows it.
@immutable
class CollectionCatalogState<T> {
  const CollectionCatalogState({
    this.items = const [],
    this.total = 0,
    this.isLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.moreError,
  });

  final List<T> items;
  final int total;

  /// The first page is on its way and nothing is listed yet.
  final bool isLoading;
  final bool isLoadingMore;

  /// The first page failed: nothing to show but this.
  final Object? error;

  /// A later page failed; the rows already loaded stay.
  final Object? moreError;

  bool get hasMore => items.length < total;

  CollectionCatalogState<T> copyWith({
    List<T>? items,
    int? total,
    bool? isLoading,
    bool? isLoadingMore,
    Object? error,
    Object? moreError,
    bool clearError = false,
    bool clearMoreError = false,
  }) => CollectionCatalogState<T>(
    items: items ?? this.items,
    total: total ?? this.total,
    isLoading: isLoading ?? this.isLoading,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    error: clearError ? null : (error ?? this.error),
    moreError: clearMoreError ? null : (moreError ?? this.moreError),
  );
}

typedef _PageFetch<T> =
    Future<({List<T> items, int total})> Function(int offset);

class CollectionCatalogNotifier<T>
    extends StateNotifier<CollectionCatalogState<T>> {
  CollectionCatalogNotifier(this._fetch, {required this.idOf})
    : super(CollectionCatalogState<T>()) {
    refresh();
  }

  final _PageFetch<T> _fetch;

  /// What makes a row itself: a page that repeats one adds nothing.
  final String Function(T item) idOf;

  /// Counts reads, so a refresh started while a page was loading wins.
  int _generation = 0;

  /// A read from the top is on its way. No further page is asked for until
  /// it lands: its offset would belong to the list being replaced.
  bool _refreshing = false;

  /// Reads the catalog again from the top.
  Future<void> refresh() async {
    final generation = ++_generation;
    _refreshing = true;
    state = state.copyWith(
      isLoading: state.items.isEmpty,
      isLoadingMore: false,
      clearError: true,
      clearMoreError: true,
    );
    try {
      final page = await _fetch(0);
      if (!mounted || generation != _generation) return;
      _refreshing = false;
      state = CollectionCatalogState<T>(
        items: _distinct(const [], page.items),
        total: page.total,
        isLoading: false,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _refreshing = false;
      state = CollectionCatalogState<T>(isLoading: false, error: error);
    }
  }

  /// Reads the next page, or tries the one that failed again. The rows
  /// already listed stay whatever happens.
  Future<void> loadMore() async {
    if (_refreshing ||
        state.isLoading ||
        state.isLoadingMore ||
        !state.hasMore) {
      return;
    }
    final generation = _generation;
    final offset = state.items.length;
    state = state.copyWith(isLoadingMore: true, clearMoreError: true);
    try {
      final page = await _fetch(offset);
      if (!mounted || generation != _generation) return;
      final items = _distinct(state.items, page.items);
      state = state.copyWith(
        items: items,
        // A page that adds nothing new ends the list, whatever the total
        // says, so the list cannot ask for it forever.
        total: items.length == state.items.length ? items.length : page.total,
        isLoadingMore: false,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      state = state.copyWith(isLoadingMore: false, moreError: error);
    }
  }

  List<T> _distinct(List<T> current, List<T> incoming) {
    final seen = {for (final item in current) idOf(item)};
    return [
      ...current,
      for (final item in incoming)
        if (seen.add(idOf(item))) item,
    ];
  }
}

/// The published books a query matches, in the team's order.
final collectionCatalogProvider = StateNotifierProvider.autoDispose.family<
  CollectionCatalogNotifier<Collection>,
  CollectionCatalogState<Collection>,
  CollectionSearchQuery
>((ref, query) {
  final reader = ref.watch(collectionsReaderProvider);
  return CollectionCatalogNotifier<Collection>((offset) async {
    final page = await reader.searchBooks(query, offset);
    return (items: page.items, total: page.total);
  }, idOf: (collection) => collection.id);
});

/// The authors of published collections, most collections first. The rail
/// lists them, so a page is larger than a catalog page.
final collectionAuthorsProvider = StateNotifierProvider.autoDispose<
  CollectionCatalogNotifier<CollectionAuthor>,
  CollectionCatalogState<CollectionAuthor>
>((ref) {
  final reader = ref.watch(collectionsReaderProvider);
  return CollectionCatalogNotifier<CollectionAuthor>(
    (offset) =>
        reader.searchAuthors(const CollectionSearchQuery(), offset, limit: 100),
    idOf: (author) => author.id,
  );
});

/// The catalog's order with the collections this account starred first, as
/// the phone lists them. Stable: starred keep their order, and so do the
/// rest.
List<Collection> pinStarredCollections(
  List<Collection> items,
  bool Function(Collection collection) isStarred,
) {
  final starred = <Collection>[];
  final rest = <Collection>[];
  for (final item in items) {
    (isStarred(item) ? starred : rest).add(item);
  }
  return starred.isEmpty ? items : [...starred, ...rest];
}
