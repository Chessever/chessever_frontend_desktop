/// Collections: the published collections catalog, drawn as a read-only
/// Library.
///
/// The layout is Library Home's: a rail on the left (here the catalog and
/// its authors), the 48px bar with search and filters, the catalog list on
/// top and the selected collection's games beside a board preview below. A
/// double click opens a collection in its own tab, as a database does. Every
/// surface is a Library widget; nothing here draws its own chrome.
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/library_pane.dart'
    show
        LibraryEmptyState,
        LibraryHomeBar,
        LibraryRailGroupHeader,
        LibraryRailHeader,
        LibraryRailLoading,
        LibraryRailRow,
        LibraryReadOnlyGamesPreview,
        LibraryWorkspaceHeader,
        LibraryWorkspaceToolbar;
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_pane_navigation.dart';
import 'package:chessever/desktop/state/collections_catalog.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/desktop/widgets/collections/collection_catalog_row.dart';
import 'package:chessever/desktop/widgets/collections/collection_reading_views.dart';
import 'package:chessever/desktop/widgets/collections/collection_text.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_metrics.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/library/library_catalog_row.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// An author the catalog should narrow to, asked for from outside the pane
/// (the "by ..." credit of an opened collection). The pane takes it and
/// clears it.
final collectionsAuthorRequestProvider = StateProvider<CollectionAuthor?>(
  (_) => null,
);

/// Opens Collections on [author]'s collections.
void showCollectionsByAuthor(BuildContext context, CollectionAuthor author) {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(collectionsAuthorRequestProvider.notifier).state = author;
  openDesktopPaneFromContainer(container, DesktopPane.collections);
}

/// The filters a published collection can be searched by.
const Set<DesktopGameFilterSection> _catalogFilterSections = {
  DesktopGameFilterSection.eco,
  DesktopGameFilterSection.year,
};

const Set<DesktopGameFilterSection> _collectionFilterSections = {
  DesktopGameFilterSection.eco,
  DesktopGameFilterSection.result,
  DesktopGameFilterSection.year,
};

/// [text] and [filter] as the API takes them, narrowed to [author] when one
/// is chosen and in the order [sort] asks for.
@visibleForTesting
CollectionSearchQuery collectionQueryFor({
  required String text,
  required GameFilter filter,
  CollectionAuthor? author,
  CollectionCatalogSort sort = const CollectionCatalogSort.standard(),
  DateTime? now,
}) {
  final thisYear = (now ?? DateTime.now()).year;
  final years =
      filter.minYear != GameFilter.defaultMinYear || filter.maxYear != thisYear;
  return CollectionSearchQuery(
    text: text.trim(),
    eco: (filter.eco.code ?? '').trim().toUpperCase(),
    result: filter.result.statusValue ?? '',
    minYear: years ? filter.minYear : null,
    maxYear: years ? filter.maxYear : null,
    authorId: author != null && author.hasCatalogIdentity ? author.id : '',
    author: author != null && !author.hasCatalogIdentity ? author.name : '',
    sort: sort.sort,
    order: sort.order,
  );
}

/// What the reader is told when the catalog could not be read in [asked]'s
/// order. [refused] is the server answering that it does not know the order,
/// which is how a sort it has yet to learn looks.
@visibleForTesting
String collectionSortFailedMessage(
  CollectionCatalogSort asked, {
  required bool refused,
}) {
  final by = asked.column?.api ?? 'default';
  if (!refused) return 'Could not sort by $by. Try again.';
  return asked.isNatural
      ? 'Sorting by $by is not available yet.'
      : 'Sorting by $by in reverse is not available yet.';
}

int _collectionFilterCount(GameFilter filter) {
  final thisYear = DateTime.now().year;
  return (filter.eco.isAll ? 0 : 1) +
      (filter.result == GameResultFilter.all ? 0 : 1) +
      (filter.minYear != GameFilter.defaultMinYear || filter.maxYear != thisYear
          ? 1
          : 0);
}

/// A search box's text, a beat after the reader stops typing.
String _useDebounced(String value, Duration delay) {
  final settled = useState(value);
  useEffect(() {
    if (value == settled.value) return null;
    final timer = Timer(delay, () => settled.value = value);
    return timer.cancel;
  }, [value]);
  return settled.value;
}

/// [chosen] as the catalog knows them: the entry with the same id, or with
/// the same name when the credit carried no catalog id.
@visibleForTesting
CollectionAuthor? resolveCollectionAuthor(
  CollectionAuthor? chosen,
  List<CollectionAuthor> known,
) {
  if (chosen == null) return null;
  final name = chosen.name.trim().toLowerCase();
  return known.firstWhereOrNull((author) => author.id == chosen.id) ??
      known.firstWhereOrNull(
        (author) => author.name.trim().toLowerCase() == name,
      ) ??
      chosen;
}

class CollectionsPane extends HookConsumerWidget {
  const CollectionsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchController = useTextEditingController();
    final typed = useState('');
    final text = _useDebounced(typed.value, const Duration(milliseconds: 300));
    final filter = useState(GameFilter());
    final author = useState<CollectionAuthor?>(null);
    final selectedSlug = useState<String?>(null);
    final splitController = useMemoized(ResizableSplitViewController.new);

    // An author asked for from an opened collection's credit.
    final requested = ref.watch(collectionsAuthorRequestProvider);
    useEffect(() {
      if (requested == null) return null;
      Future.microtask(() {
        author.value = requested;
        selectedSlug.value = null;
        ref.read(collectionsAuthorRequestProvider.notifier).state = null;
      });
      return null;
    }, [requested]);

    // A credit only knows the author's name and id. The catalog's own entry
    // has the photo, the description and the counts.
    final knownAuthors = ref.watch(
      collectionAuthorsProvider.select((state) => state.items),
    );
    final shownAuthor = resolveCollectionAuthor(author.value, knownAuthors);

    // The order the headers ask for, and the order of the rows on screen:
    // the same once the first page in the new order is here. Until then the
    // rows stay as they were, so a press never blanks the list.
    final sort = useState(const CollectionCatalogSort.standard());
    final shownSort = useState(const CollectionCatalogSort.standard());
    // Orders the server answered it does not know. A header steps over them.
    final refusedSorts = useRef(<CollectionCatalogSort>{});

    CollectionSearchQuery queryIn(CollectionCatalogSort order) =>
        collectionQueryFor(
          text: text,
          filter: filter.value,
          author: shownAuthor,
          sort: order,
        );
    final asked = ref.watch(collectionCatalogProvider(queryIn(sort.value)));
    final awaitingSort = sort.value != shownSort.value;
    final query = queryIn(shownSort.value);
    final catalog =
        awaitingSort ? ref.watch(collectionCatalogProvider(query)) : asked;

    // The asked order arrives, or the read fails and the catalog goes back
    // to the order it had.
    useEffect(() {
      if (!awaitingSort || asked.isLoading) return null;
      final order = sort.value;
      final failure = asked.error;
      // A search that fails in the old order too is not the order's doing,
      // and the team's own order is never one to go back from.
      final sortFailed =
          failure != null && catalog.error == null && !order.isStandard;
      Future.microtask(() {
        if (!context.mounted || sort.value != order) return;
        if (!sortFailed) {
          shownSort.value = order;
          return;
        }
        final refused =
            failure is CollectionsRequestException && failure.statusCode == 400;
        if (refused) refusedSorts.value.add(order);
        sort.value = shownSort.value;
        showDesktopToast(
          context,
          collectionSortFailedMessage(order, refused: refused),
          error: true,
        );
      });
      return null;
    }, [awaitingSort, asked.isLoading, asked.error, sort.value]);

    final favorites = ref.watch(favoriteCollectionSlugsProvider);
    final pinned = shownSort.value.isStandard;
    final items = useMemoized(
      () =>
          pinned
              ? pinStarredCollections(
                catalog.items,
                (collection) => favorites.contains(collection.slug),
              )
              : catalog.items,
      [catalog.items, favorites, pinned],
    );
    // A new order can leave the open collection off the first page. It stays
    // open from what was last read of it until its row is paged in again.
    final lastSelected = useRef<Collection?>(null);
    final selected =
        items.firstWhereOrNull(
          (collection) => collection.slug == selectedSlug.value,
        ) ??
        (lastSelected.value?.slug == selectedSlug.value
            ? lastSelected.value
            : null);
    lastSelected.value = selected;

    void selectAuthor(CollectionAuthor? next) {
      author.value = next;
      selectedSlug.value = null;
    }

    void pressSort(CollectionSortColumn column) {
      final next = sort.value.after(column, refused: refusedSorts.value);
      if (next != sort.value) {
        sort.value = next;
        return;
      }
      // Everything this column offers was refused: say so again rather than
      // let the press do nothing.
      showDesktopToast(
        context,
        collectionSortFailedMessage(
          CollectionCatalogSort.natural(column),
          refused: true,
        ),
        error: true,
      );
    }

    Future<void> editFilters() async {
      final next = await showDesktopGameFilterDialog(
        context: context,
        currentFilter: filter.value,
        sections: _catalogFilterSections,
      );
      if (next == null) return;
      // Clearing the filters clears the order with them, as on the phone.
      if (_collectionFilterCount(next) == 0 &&
          _collectionFilterCount(filter.value) > 0) {
        sort.value = shownSort.value = const CollectionCatalogSort.standard();
      }
      filter.value = next;
    }

    void refresh() {
      // The server may have learned an order since it refused it.
      refusedSorts.value.clear();
      ref.read(collectionCatalogProvider(query).notifier).refresh();
      ref.read(collectionAuthorsProvider.notifier).refresh();
    }

    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBackgroundColor,
        child: ResizableSplitView(
          axis: Axis.horizontal,
          storageKey: 'collections_pane.main',
          controller: splitController,
          children: [
            SplitChild(
              minSize: 200,
              maxSize: 420,
              initialWeight: 0.20,
              label: 'Collections',
              collapsedIcon: Icons.view_sidebar_outlined,
              child: _CollectionsRail(
                selectedAuthor: shownAuthor,
                onSelectAuthor: selectAuthor,
                onCollapse: () => splitController.collapse(0),
              ),
            ),
            SplitChild(
              minSize: 480,
              initialWeight: 0.80,
              label: 'Content',
              dismissible: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CollectionsBar(
                    author: shownAuthor,
                    onBack: () => selectAuthor(null),
                    searchController: searchController,
                    onQueryChanged: (value) => typed.value = value,
                    filter: filter.value,
                    activeFilters: _collectionFilterCount(filter.value),
                    onEditFilters: () => unawaited(editFilters()),
                    onRefresh: refresh,
                  ),
                  Expanded(
                    child: ResizableSplitView(
                      axis: Axis.vertical,
                      storageKey: 'collections_pane.home_split',
                      children: [
                        SplitChild(
                          minSize: 124,
                          initialWeight: 0.30,
                          label: 'Catalog',
                          child: _CatalogList(
                            state: catalog,
                            items: items,
                            // An order never empties the catalog.
                            searching:
                                queryIn(
                                  const CollectionCatalogSort.standard(),
                                ).isActive,
                            sort: sort.value,
                            shownSort: shownSort.value,
                            onSort: pressSort,
                            selectedSlug: selectedSlug.value,
                            onSelect:
                                (collection) =>
                                    selectedSlug.value = collection.slug,
                            onOpen:
                                (collection) =>
                                    openCollectionTab(ref, collection),
                            onLoadMore:
                                () =>
                                    ref
                                        .read(
                                          collectionCatalogProvider(
                                            query,
                                          ).notifier,
                                        )
                                        .loadMore(),
                            onRetry:
                                () =>
                                    ref
                                        .read(
                                          collectionCatalogProvider(
                                            query,
                                          ).notifier,
                                        )
                                        .refresh(),
                          ),
                        ),
                        SplitChild(
                          minSize: 260,
                          initialWeight: 0.70,
                          label: 'Preview',
                          child:
                              selected != null
                                  ? _CollectionPreview(
                                    key: ValueKey(selected.slug),
                                    collection: selected,
                                  )
                                  : shownAuthor != null
                                  ? _AuthorAbout(
                                    author: shownAuthor,
                                    listed: catalog.total,
                                  )
                                  : const LibraryEmptyState(
                                    icon: Icons.auto_stories_outlined,
                                    title: 'About collections',
                                    message:
                                        'Explore curated chess games with '
                                        'their original PGN annotations and '
                                        'variations. Select a collection to '
                                        'preview its games here, or open it '
                                        'to read about it and browse its '
                                        'players.',
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rail

class _CollectionsRail extends ConsumerWidget {
  const _CollectionsRail({
    required this.selectedAuthor,
    required this.onSelectAuthor,
    required this.onCollapse,
  });

  final CollectionAuthor? selectedAuthor;
  final ValueChanged<CollectionAuthor?> onSelectAuthor;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authors = ref.watch(collectionAuthorsProvider);
    final all = ref.watch(
      collectionCatalogProvider(const CollectionSearchQuery()),
    );
    return Container(
      color: kBlack2Color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LibraryRailHeader(title: 'Collections', onCollapse: onCollapse),
          Expanded(
            child: ListView(
              physics: const DesktopScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 10),
              children: [
                LibraryRailGroupHeader(label: 'Catalog', count: all.total),
                LibraryRailRow(
                  label: 'All collections',
                  icon: Icons.auto_stories_outlined,
                  selected: selectedAuthor == null,
                  onTap: () => onSelectAuthor(null),
                ),
                const SizedBox(height: 12),
                LibraryRailGroupHeader(label: 'Authors', count: authors.total),
                if (authors.isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: LibraryRailLoading(),
                  )
                else if (authors.error != null)
                  _RailNote(
                    text: 'Authors could not be loaded.',
                    action: 'Try again',
                    onAction:
                        () =>
                            ref
                                .read(collectionAuthorsProvider.notifier)
                                .refresh(),
                  )
                else if (authors.items.isEmpty)
                  const _RailNote(
                    text:
                        'Authors will appear here when their collections '
                        'are published.',
                  )
                else ...[
                  for (final author in authors.items)
                    LibraryRailRow(
                      label: author.name,
                      icon: Icons.person_outline_rounded,
                      leading: _AuthorPhoto(url: author.avatarUrl, size: 16),
                      trailingLabel: '${author.bookCount}',
                      selected: selectedAuthor?.id == author.id,
                      onTap: () => onSelectAuthor(author),
                    ),
                  if (authors.isLoadingMore)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: LibraryRailLoading(),
                    )
                  else if (authors.hasMore)
                    LibraryRailRow(
                      label:
                          authors.moreError != null
                              ? 'Try loading more again'
                              : 'Show more authors',
                      icon: Icons.expand_more_rounded,
                      selected: false,
                      onTap:
                          () =>
                              ref
                                  .read(collectionAuthorsProvider.notifier)
                                  .loadMore(),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailNote extends StatelessWidget {
  const _RailNote({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          if (action != null && onAction != null) ...[
            const SizedBox(height: 8),
            DesktopToolbarPillButton(
              label: action!,
              icon: Icons.refresh_rounded,
              height: 30,
              onPress: onAction,
            ),
          ],
        ],
      ),
    );
  }
}

/// An author's photo as a small circle, or the person glyph without one.
class _AuthorPhoto extends StatelessWidget {
  const _AuthorPhoto({required this.url, required this.size});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      Icons.person_outline_rounded,
      size: size * 0.9,
      color: kLightGreyColor,
    );
    final address = url?.trim() ?? '';
    if (address.isEmpty) return SizedBox.square(dimension: size, child: glyph);
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: address,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, _) => SizedBox.square(dimension: size, child: glyph),
        errorWidget:
            (_, _, _) => SizedBox.square(dimension: size, child: glyph),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bar

class _CollectionsBar extends StatelessWidget {
  const _CollectionsBar({
    required this.author,
    required this.onBack,
    required this.searchController,
    required this.onQueryChanged,
    required this.filter,
    required this.activeFilters,
    required this.onEditFilters,
    required this.onRefresh,
  });

  final CollectionAuthor? author;
  final VoidCallback onBack;
  final TextEditingController searchController;
  final ValueChanged<String> onQueryChanged;
  final GameFilter filter;
  final int activeFilters;
  final VoidCallback onEditFilters;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final insideAuthor = author != null;
    return LibraryHomeBar(
      child: Row(
        children: [
          const SizedBox(
            width: 28,
            child: Icon(
              Icons.auto_stories_outlined,
              size: 17,
              color: kPrimaryColor,
            ),
          ),
          const SizedBox(width: 4),
          if (insideAuthor) ...[
            DesktopHeaderIconButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back to all collections',
              onPress: onBack,
            ),
            const SizedBox(width: 4),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: insideAuthor ? 220 : 110),
            child: Text(
              insideAuthor ? author!.name : 'Collections',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: DesktopSearchField(
                controller: searchController,
                hintText: 'Search collections',
                maxWidth: 260,
                onChanged: onQueryChanged,
                onClear: () {
                  searchController.clear();
                  onQueryChanged('');
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          DesktopGameFilterButton(
            filter: filter,
            activeCountOverride: activeFilters,
            onPress: onEditFilters,
          ),
          const SizedBox(width: 4),
          DesktopHeaderIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Refresh collections',
            onPress: onRefresh,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Catalog list

enum _CollectionRowAction { open, star }

class _CatalogList extends HookConsumerWidget {
  const _CatalogList({
    required this.state,
    required this.items,
    required this.searching,
    required this.sort,
    required this.shownSort,
    required this.onSort,
    required this.selectedSlug,
    required this.onSelect,
    required this.onOpen,
    required this.onLoadMore,
    required this.onRetry,
  });

  final CollectionCatalogState<Collection> state;
  final List<Collection> items;
  final bool searching;

  /// The order the headers show: what was last asked for.
  final CollectionCatalogSort sort;

  /// The order [items] are in.
  final CollectionCatalogSort shownSort;
  final ValueChanged<CollectionSortColumn> onSort;
  final String? selectedSlug;
  final ValueChanged<Collection> onSelect;
  final ValueChanged<Collection> onOpen;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No remembered offset: a new order's list starts from its top.
    final scrollController = useScrollController(keepScrollOffset: false);

    // The next page is asked for as the list nears its end, and also when a
    // short first page does not fill the pane at all.
    // The listener outlives a rebuild, so it calls whichever callback the
    // latest build was given: a new search has its own next page.
    final loadMore = useRef(onLoadMore);
    loadMore.value = onLoadMore;
    useEffect(() {
      void maybeLoadMore() {
        if (!scrollController.hasClients) return;
        if (scrollController.position.extentAfter < 600) loadMore.value();
      }

      scrollController.addListener(maybeLoadMore);
      WidgetsBinding.instance.addPostFrameCallback((_) => maybeLoadMore());
      return () => scrollController.removeListener(maybeLoadMore);
    }, [scrollController, items.length, state.hasMore]);

    Future<void> showMenu(Collection collection, Offset position) async {
      final starred = ref.read(collectionStarredProvider(collection.slug));
      final action = await showDesktopContextMenu<_CollectionRowAction>(
        context: context,
        position: position,
        entries: [
          const DesktopContextMenuItem(
            value: _CollectionRowAction.open,
            icon: Icons.open_in_new_rounded,
            label: 'Open',
          ),
          DesktopContextMenuItem(
            value: _CollectionRowAction.star,
            icon: starred ? Icons.star_outline_rounded : Icons.star_rounded,
            label: starred ? 'Unstar' : 'Star',
          ),
        ],
      );
      if (!context.mounted) return;
      switch (action) {
        case _CollectionRowAction.open:
          onOpen(collection);
        case _CollectionRowAction.star:
          unawaited(pressCollectionStar(context, collection));
        case null:
          break;
      }
    }

    final Widget body;
    if (state.isLoading) {
      body = const CollectionLoading();
    } else if (state.error != null) {
      final error = state.error;
      final badSearch =
          error is CollectionsRequestException && error.statusCode == 400;
      body =
          badSearch
              ? const LibraryEmptyState(
                icon: Icons.search_off_rounded,
                title: 'Check your search',
                message:
                    'Use an ECO code such as B20 or a tag like '
                    '[White "Carlsen"].',
              )
              : CollectionLoadError(
                title: "Couldn't load collections.",
                error: error,
                onRetry: onRetry,
              );
    } else if (items.isEmpty) {
      body =
          searching
              ? const LibraryEmptyState(
                icon: Icons.search_off_rounded,
                title: 'No matches',
                message: 'Try another search or clear filters.',
              )
              : const LibraryEmptyState(
                icon: Icons.auto_stories_outlined,
                title: 'No collections yet',
                message: 'Published collections will be listed here.',
              );
    } else {
      final hasFooter =
          state.isLoadingMore || state.moreError != null || state.hasMore;
      body = ListView.builder(
        // A list of its own for each order, so none inherits a scroll.
        key: ValueKey(shownSort),
        controller: scrollController,
        physics: const DesktopScrollPhysics(),
        padding: EdgeInsets.zero,
        itemExtent: kLibraryCatalogRowHeight,
        itemCount: items.length + (hasFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= items.length) {
            return _CatalogFooter(
              failed: state.moreError != null,
              onRetry: onLoadMore,
            );
          }
          final collection = items[index];
          return CollectionCatalogRow(
            key: ValueKey('collection-${collection.id}'),
            collection: collection,
            selected: collection.slug == selectedSlug,
            onSelect: () => onSelect(collection),
            onOpen: () => onOpen(collection),
            onContextMenu:
                (position) => unawaited(showMenu(collection, position)),
          );
        },
      );
    }

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CollectionCatalogHeader(sort: sort, onSort: onSort),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// The last line of the catalog while more of it is on the way, or after a
/// page failed (the rows above stay).
class _CatalogFooter extends StatelessWidget {
  const _CatalogFooter({required this.failed, required this.onRetry});

  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (!failed) return const CollectionLoading();
    return Center(
      child: DesktopToolbarPillButton(
        label: "Couldn't load more. Try again",
        icon: Icons.refresh_rounded,
        height: 30,
        onPress: onRetry,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preview of the selected collection

class _CollectionPreview extends ConsumerWidget {
  const _CollectionPreview({super.key, required this.collection});

  /// The catalog row, shown until the collection itself is read.
  final Collection collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = collection.slug;
    final detailAsync = ref.watch(collectionDetailProvider(slug));
    final detail = detailAsync.valueOrNull ?? collection;
    return _CollectionGames(
      collection: detail,
      // The lock is the server's to call: wait for its verdict on a Premium
      // collection instead of asking for games it would refuse.
      // Only the first read waits: a re-read (confirming a purchase) keeps
      // what is on screen, and with it the button that started it.
      awaitingVerdict:
          detailAsync.isLoading &&
          !detailAsync.hasValue &&
          collection.access == CollectionAccess.premium,
      splitStorageKey: 'collections_pane.preview.wide',
      emptyMessage: 'Open the collection to read about it.',
    );
  }
}

/// A collection's games in the Library's table beside its board preview, or
/// what stands in for them: the locked contents, a spinner, an error with a
/// retry, an empty state.
class _CollectionGames extends ConsumerWidget {
  const _CollectionGames({
    required this.collection,
    required this.splitStorageKey,
    required this.emptyMessage,
    this.awaitingVerdict = false,
    this.query = const CollectionSearchQuery(),
    this.player,
    this.section,
  });

  final Collection collection;
  final String splitStorageKey;
  final String emptyMessage;
  final bool awaitingVerdict;

  /// A search inside the collection, matched by the server.
  final CollectionSearchQuery query;

  /// Only this player's games.
  final CollectionPlayer? player;

  /// Only this chapter's or round's games. A part stands for its chapters.
  final CollectionSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = collection.slug;
    if (awaitingVerdict) return const CollectionLoading();
    if (watchCollectionLocked(ref, collection)) {
      return CollectionLockedContents(collection: collection);
    }
    final searching = query.isActive;
    final CollectionGamesFilter filter = (
      slug: slug,
      query: query,
      player: null,
    );
    final gamesAsync =
        searching
            ? ref.watch(collectionFilteredGamesProvider(filter))
            : ref.watch(collectionGamesProvider(slug));
    void retry() {
      ref.invalidate(collectionDetailProvider(slug));
      if (searching) {
        ref.invalidate(collectionFilteredGamesProvider(filter));
      } else {
        ref.invalidate(collectionGamesProvider(slug));
      }
    }

    return gamesAsync.when(
      loading: () => const CollectionLoading(),
      error: (error, _) {
        // The server kept the games from this account: the same preview a
        // collection known to be locked shows, never an error.
        if (isCollectionPremiumGate(error)) {
          return CollectionLockedContents(collection: collection);
        }
        return CollectionLoadError(
          title: "Couldn't load the games.",
          error: error,
          onRetry: retry,
        );
      },
      data: (games) {
        final sectionId = section?.id;
        final scoped = _scopeGames(games, player: player, section: section);
        if (scoped.isEmpty) {
          return LibraryEmptyState(
            icon:
                searching || player != null || sectionId != null
                    ? Icons.search_off_rounded
                    : Icons.auto_stories_outlined,
            title:
                searching || player != null
                    ? 'No games match this search.'
                    : sectionId != null
                    ? 'No games in this chapter or round.'
                    : 'No games in this collection yet.',
            message:
                searching || player != null || sectionId != null
                    ? 'Try another search or clear filters.'
                    : emptyMessage,
          );
        }
        final rows = [for (final game in scoped) game.row];
        return LibraryReadOnlyGamesPreview(
          scopeId: [
            slug,
            query.hashCode,
            player?.key ?? '',
            sectionId ?? '',
          ].join('|'),
          rows: rows,
          splitStorageKey: splitStorageKey,
          onOpen:
              (SavedAnalysis row, displayed, initialFen) => openCollectionGame(
                ref,
                collectionTitle: collection.title,
                games: scoped,
                row: row,
                displayed: displayed,
                initialFen: initialFen,
              ),
        );
      },
    );
  }
}

/// [games] narrowed to one player and to one section. A part holds no games
/// of its own, so it stands for every chapter under it.
@visibleForTesting
List<CollectionGame> scopeCollectionGames(
  List<CollectionGame> games, {
  CollectionPlayer? player,
  CollectionSection? section,
}) => _scopeGames(games, player: player, section: section);

List<CollectionGame> _scopeGames(
  List<CollectionGame> games, {
  CollectionPlayer? player,
  CollectionSection? section,
}) {
  if (player == null && section == null) return games;
  final keys =
      player == null ? const <String>{} : {player.key, ...player.aliasKeys};
  final sectionIds =
      section == null
          ? const <String>{}
          : {
            section.id,
            for (final below in _flatSections(section.children)) below.id,
          };
  return [
    for (final game in games)
      if ((player == null || keys.any(game.card.involves)) &&
          (section == null || sectionIds.contains(game.sectionId)))
        game,
  ];
}

/// An author's photo and description, shown while their collections are
/// listed and none is selected.
class _AuthorAbout extends StatelessWidget {
  const _AuthorAbout({required this.author, required this.listed});

  final CollectionAuthor author;

  /// How many of their collections the catalog lists right now: the count
  /// for an author the catalog has no entry for.
  final int listed;

  @override
  Widget build(BuildContext context) {
    final paragraphs = collectionParagraphs(author.about);
    final hasPhoto = author.avatarUrl?.trim().isNotEmpty ?? false;
    final count = author.bookCount > 0 ? author.bookCount : listed;
    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (hasPhoto) ...[
                      _AuthorPhoto(url: author.avatarUrl, size: 56),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            author.name,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              if (count == 1)
                                '1 collection'
                              else if (count > 1)
                                '$count collections',
                              if (author.gameCount > 0)
                                collectionGamesLabel(author.gameCount),
                            ].join(' · '),
                            style: const TextStyle(
                              color: kLightGreyColor,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (paragraphs.isEmpty)
                  const Text(
                    'No author description available yet.',
                    style: TextStyle(color: kWhiteColor70, fontSize: 13),
                  )
                else
                  for (var i = 0; i < paragraphs.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    SelectableText(
                      paragraphs[i],
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 13,
                        height: 1.55,
                      ),
                    ),
                  ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// An opened collection

enum _CollectionTab { about, games, players }

/// One collection in its own tab: the Library's database workspace header and
/// toolbar over About, Games and Players.
class CollectionWorkspacePane extends HookConsumerWidget {
  const CollectionWorkspacePane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = ref.watch(
      collectionWorkspaceArgsByTabIdProvider.select((byTab) => byTab[tabId]),
    );
    if (args == null) {
      return const LibraryEmptyState(
        icon: Icons.auto_stories_outlined,
        title: 'This collection is no longer open',
        message: 'Open it again from Collections.',
      );
    }
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBackgroundColor,
        child: _CollectionWorkspace(key: ValueKey(args.slug), args: args),
      ),
    );
  }
}

class _CollectionWorkspace extends HookConsumerWidget {
  const _CollectionWorkspace({super.key, required this.args});

  final CollectionWorkspaceArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = args.slug;
    final detailAsync = ref.watch(collectionDetailProvider(slug));
    final detail = detailAsync.valueOrNull;
    final searchController = useTextEditingController();
    final typed = useState('');
    final text = _useDebounced(typed.value, const Duration(milliseconds: 200));
    final filter = useState(GameFilter());
    final tab = useState<_CollectionTab?>(null);
    final player = useState<CollectionPlayer?>(null);
    final sectionId = useState<String?>(null);

    // Opening a book counts as a read, once per time it is opened.
    final counted = useRef(false);
    useEffect(() {
      if (detail == null || counted.value) return null;
      counted.value = true;
      unawaited(
        trackCollectionRead(
          ProviderScope.containerOf(context, listen: false),
          detail,
        ),
      );
      return null;
    }, [detail?.slug]);

    if (detail == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LibraryWorkspaceHeader(
            icon: Icons.auto_stories_outlined,
            title: args.title,
            subtitle: '',
            badge: 'Collection',
          ),
          const FDivider(),
          Expanded(
            child:
                detailAsync.hasError
                    ? CollectionLoadError(
                      title: "Couldn't load this collection.",
                      error: detailAsync.error,
                      onRetry:
                          () => ref.invalidate(collectionDetailProvider(slug)),
                    )
                    : const CollectionLoading(),
          ),
        ],
      );
    }

    final locked = watchCollectionLocked(ref, detail);
    // A locked collection opens on what it can show; an open one on its games.
    final shownTab =
        tab.value ?? (locked ? _CollectionTab.about : _CollectionTab.games);
    final playersAsync =
        locked ? null : ref.watch(collectionPlayersProvider(slug));
    final players = playersAsync?.valueOrNull;
    final query = collectionQueryFor(text: text, filter: filter.value);
    final sections = _flatSections(detail.sections);
    final section = sections.firstWhereOrNull((s) => s.id == sectionId.value);

    Future<void> editFilters() async {
      final next = await showDesktopGameFilterDialog(
        context: context,
        currentFilter: filter.value,
        sections: _collectionFilterSections,
      );
      if (next != null) filter.value = next;
    }

    Future<void> pickSection(Offset position) async {
      final picked = await showDesktopContextMenu<String>(
        context: context,
        position: position,
        width: 320,
        entries: [
          const DesktopContextMenuItem(
            value: '',
            icon: Icons.all_inbox_rounded,
            label: 'All games',
          ),
          for (final s in sections)
            DesktopContextMenuItem(
              value: s.id,
              icon:
                  s.kind == CollectionSectionKind.part
                      ? Icons.folder_open_rounded
                      : Icons.subdirectory_arrow_right_rounded,
              label: _sectionLabel(s),
            ),
        ],
      );
      if (picked == null) return;
      sectionId.value = picked.isEmpty ? null : picked;
    }

    void showAuthor() {
      final name = detail.author?.trim() ?? '';
      if (name.isEmpty) return;
      showCollectionsByAuthor(
        context,
        CollectionAuthor(id: detail.authorId ?? name, name: name),
      );
    }

    Widget pill(_CollectionTab value, String label, IconData icon) =>
        DesktopToolbarPillButton(
          label: label,
          icon: icon,
          height: desktopToolbarControlHeight,
          tone:
              shownTab == value
                  ? DesktopToolbarPillTone.primary
                  : DesktopToolbarPillTone.neutral,
          onPress: () => tab.value = value,
        );

    final views = collectionViewCount(ref, detail);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LibraryWorkspaceHeader(
          icon:
              detail.kind == CollectionKind.event
                  ? Icons.emoji_events_outlined
                  : Icons.auto_stories_outlined,
          title: detail.title,
          subtitle: collectionFactsLine(detail),
          badge: locked ? 'Premium' : collectionKindLabel(detail.kind),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (detail.kind == CollectionKind.book) ...[
                const Icon(
                  Icons.visibility_outlined,
                  size: 14,
                  color: kLightGreyColor,
                ),
                const SizedBox(width: 5),
                LibraryCatalogMutedCell('$views'),
                const SizedBox(width: 12),
              ],
              // The glyph is inset in the square that takes the pointer;
              // moved out by that much, it ends on the margin the toolbar
              // under it ends on.
              Transform.translate(
                offset: const Offset(6, 0),
                child: CollectionStarButton(collection: detail),
              ),
            ],
          ),
        ),
        const FDivider(),
        LibraryWorkspaceToolbar(
          controller: searchController,
          hintText: 'Search this collection: players, events, openings, ECO',
          onSearchChanged: (value) => typed.value = value,
          onSearchClear: () {
            searchController.clear();
            typed.value = '';
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              pill(_CollectionTab.about, 'About', Icons.info_outline_rounded),
              const SizedBox(width: 4),
              pill(_CollectionTab.games, 'Games', Icons.table_rows_outlined),
              const SizedBox(width: 4),
              pill(_CollectionTab.players, 'Players', Icons.groups_outlined),
              const SizedBox(width: 12),
              DesktopGameFilterButton(
                filter: filter.value,
                activeCountOverride: _collectionFilterCount(filter.value),
                onPress: () => unawaited(editFilters()),
              ),
            ],
          ),
        ),
        if (shownTab == _CollectionTab.games &&
            !locked &&
            (sections.isNotEmpty || player.value != null))
          _GamesScopeBar(
            sectionLabel:
                sections.isEmpty
                    ? null
                    : (section == null ? 'All games' : _sectionLabel(section)),
            onPickSection: pickSection,
            playerName: player.value?.name,
            onClearPlayer: () => player.value = null,
          ),
        const FDivider(),
        Expanded(
          child: switch (shownTab) {
            _CollectionTab.about => CollectionAboutView(
              collection: detail,
              locked: locked,
              playerCount: players?.length,
              onShowAuthor: showAuthor,
            ),
            _CollectionTab.games => _CollectionGames(
              collection: detail,
              splitStorageKey: 'collections_pane.workspace.wide',
              emptyMessage: 'Its games will appear here once it has some.',
              query: query,
              player: player.value,
              section: section,
            ),
            _CollectionTab.players => _CollectionPlayers(
              collection: detail,
              locked: locked,
              players: playersAsync,
              filterText: text,
              onShowGames: (picked) {
                player.value = picked;
                tab.value = _CollectionTab.games;
              },
              onRetry: () => ref.invalidate(collectionPlayersProvider(slug)),
            ),
          },
        ),
      ],
    );
  }
}

String _sectionLabel(CollectionSection section) {
  final title = section.title?.trim() ?? '';
  if (title.isEmpty) return section.label;
  return section.label.isEmpty ? title : '${section.label}: $title';
}

/// A part, then its chapters: the order the collection lists them in.
List<CollectionSection> _flatSections(List<CollectionSection> sections) => [
  for (final section in sections) ...[
    section,
    ..._flatSections(section.children),
  ],
];

/// The line above the games that says which of them are shown: the chapter
/// or round, and the player when the table is narrowed to one.
class _GamesScopeBar extends StatelessWidget {
  const _GamesScopeBar({
    required this.sectionLabel,
    required this.onPickSection,
    required this.playerName,
    required this.onClearPlayer,
  });

  final String? sectionLabel;
  final ValueChanged<Offset> onPickSection;
  final String? playerName;
  final VoidCallback onClearPlayer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 18, 10),
      child: Row(
        children: [
          if (sectionLabel != null)
            Flexible(
              child: Builder(
                builder:
                    (context) => DesktopToolbarPillButton(
                      label: sectionLabel!,
                      icon: Icons.segment_rounded,
                      height: 30,
                      tooltip: 'Select chapter or round',
                      trailing: const Icon(
                        Icons.expand_more_rounded,
                        size: 15,
                        color: kLightGreyColor,
                      ),
                      onPress: () {
                        final box = context.findRenderObject() as RenderBox?;
                        if (box == null) return;
                        onPickSection(
                          box.localToGlobal(Offset(0, box.size.height + 4)),
                        );
                      },
                    ),
              ),
            ),
          if (sectionLabel != null && playerName != null)
            const SizedBox(width: 6),
          if (playerName != null)
            Flexible(
              child: DesktopToolbarPillButton(
                label: playerName!,
                icon: Icons.person_outline_rounded,
                height: 30,
                tone: DesktopToolbarPillTone.primary,
                tooltip: 'Show every player again',
                trailing: const Icon(Icons.close_rounded, size: 14),
                onPress: onClearPlayer,
              ),
            ),
        ],
      ),
    );
  }
}

class _CollectionPlayers extends StatelessWidget {
  const _CollectionPlayers({
    required this.collection,
    required this.locked,
    required this.players,
    required this.filterText,
    required this.onShowGames,
    required this.onRetry,
  });

  final Collection collection;
  final bool locked;
  final AsyncValue<List<CollectionPlayer>>? players;
  final String filterText;
  final ValueChanged<CollectionPlayer> onShowGames;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final async = players;
    if (locked || async == null) {
      return CollectionLockedContents(collection: collection);
    }
    return async.when(
      loading: () => const CollectionLoading(),
      error: (error, _) {
        if (isCollectionPremiumGate(error)) {
          return CollectionLockedContents(collection: collection);
        }
        return CollectionLoadError(
          title: "Couldn't load the players.",
          error: error,
          onRetry: onRetry,
        );
      },
      data: (all) {
        final needle = filterText.trim().toLowerCase();
        final shown =
            needle.isEmpty
                ? all
                : [
                  for (final player in all)
                    if (player.name.toLowerCase().contains(needle)) player,
                ];
        if (shown.isEmpty) {
          return LibraryEmptyState(
            icon:
                needle.isEmpty
                    ? Icons.groups_outlined
                    : Icons.search_off_rounded,
            title:
                needle.isEmpty
                    ? 'No players in this collection yet.'
                    : 'No players match this search.',
            message:
                needle.isEmpty
                    ? 'They appear here with its games.'
                    : 'Try another search.',
          );
        }
        return CollectionPlayersTable(players: shown, onShowGames: onShowGames);
      },
    );
  }
}
