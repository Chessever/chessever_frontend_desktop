import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/widgets/collections/collection_text.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_locked_content.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/library/library_catalog_row.dart';
import 'package:chessever/theme/app_theme.dart';

/// A collection's cover at the size of a catalog row's leading well, or the
/// well itself with the kind's glyph when it has no cover (or the image
/// cannot be read).
class CollectionCoverThumb extends StatelessWidget {
  const CollectionCoverThumb({
    super.key,
    required this.coverUrl,
    required this.kind,
    this.size = 27,
  });

  final String? coverUrl;
  final CollectionKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final well = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
      ),
      child: Icon(
        kind == CollectionKind.event
            ? Icons.emoji_events_outlined
            : Icons.auto_stories_outlined,
        size: size * 0.56,
        color: kPrimaryColor,
      ),
    );
    final url = coverUrl?.trim() ?? '';
    if (url.isEmpty) return well;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // A portrait cover keeps its title edge in a square crop.
        alignment: Alignment.topCenter,
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, _) => well,
        errorWidget: (_, _, _) => well,
      ),
    );
  }
}

/// Stars or unstars a collection: the Library's header icon button, with the
/// public star count beside it when there is one.
class CollectionStarButton extends ConsumerWidget {
  const CollectionStarButton({
    super.key,
    required this.collection,
    this.showCount = true,
  });

  final Collection collection;
  final bool showCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starred = ref.watch(collectionStarredProvider(collection.slug));
    final count = collectionStarCount(ref, collection);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showCount && count > 0) ...[
          LibraryCatalogMutedCell('$count'),
          const SizedBox(width: 2),
        ],
        DesktopHeaderIconButton(
          icon: Icons.star_outline_rounded,
          selectedIcon: Icons.star_rounded,
          selected: starred,
          tooltip: starred ? 'Unstar collection' : 'Star collection',
          onPress:
              () => unawaited(pressCollectionStar(context, ref, collection)),
        ),
      ],
    );
  }
}

/// The star press behind every collection star, with its feedback.
Future<void> pressCollectionStar(
  BuildContext context,
  WidgetRef ref,
  Collection collection,
) async {
  final outcome = await toggleCollectionStar(ref, collection);
  if (!context.mounted) return;
  switch (outcome) {
    case CollectionStarOutcome.needsAccount:
      showDesktopToast(context, 'Sign in to star collections.', error: true);
    case CollectionStarOutcome.failed:
      showDesktopToast(
        context,
        'Could not update the star. Try again.',
        error: true,
      );
    case CollectionStarOutcome.starred:
    case CollectionStarOutcome.unstarred:
      break;
  }
}

/// Which of the catalog's columns fit [width].
@immutable
class CollectionCatalogColumns {
  const CollectionCatalogColumns._({
    required this.showAuthor,
    required this.showViews,
  });

  factory CollectionCatalogColumns.forWidth(double width) =>
      CollectionCatalogColumns._(
        showAuthor: width >= 560,
        showViews: width >= 720,
      );

  final bool showAuthor;
  final bool showViews;

  static const double authorWidth = 190;
  static const double gamesWidth = 78;
  static const double viewsWidth = 66;
  static const double starWidth = 64;
}

class _CatalogColumnsLayout extends StatelessWidget {
  const _CatalogColumnsLayout({
    required this.leading,
    required this.name,
    required this.author,
    required this.games,
    required this.views,
    required this.trailing,
  });

  final Widget leading;
  final Widget name;
  final Widget author;
  final Widget games;
  final Widget views;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = CollectionCatalogColumns.forWidth(constraints.maxWidth);
        return Row(
          children: [
            SizedBox(
              width: 39,
              child: Align(alignment: Alignment.centerLeft, child: leading),
            ),
            const SizedBox(width: 5),
            Expanded(child: name),
            if (columns.showAuthor) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: CollectionCatalogColumns.authorWidth,
                child: author,
              ),
            ],
            const SizedBox(width: 12),
            SizedBox(width: CollectionCatalogColumns.gamesWidth, child: games),
            if (columns.showViews) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: CollectionCatalogColumns.viewsWidth,
                child: views,
              ),
            ],
            const SizedBox(width: 8),
            SizedBox(
              width: CollectionCatalogColumns.starWidth,
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        );
      },
    );
  }
}

/// The catalog's column headers, on the Library's header strip.
class CollectionCatalogHeader extends StatelessWidget {
  const CollectionCatalogHeader({super.key});

  @override
  Widget build(BuildContext context) {
    Widget label(String text, {TextAlign? align}) => Text(
      text,
      textAlign: align,
      maxLines: 1,
      style: kLibraryCatalogHeaderStyle,
    );
    return LibraryCatalogHeaderStrip(
      child: _CatalogColumnsLayout(
        leading: const SizedBox.shrink(),
        name: label('COLLECTION'),
        author: label('AUTHOR'),
        games: label('GAMES'),
        views: label('VIEWS'),
        trailing: label('STARS', align: TextAlign.right),
      ),
    );
  }
}

/// One published collection in the catalog, on the Library's row frame.
class CollectionCatalogRow extends ConsumerWidget {
  const CollectionCatalogRow({
    super.key,
    required this.collection,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    this.onContextMenu,
  });

  final Collection collection;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final ValueChanged<Offset>? onContextMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = watchCollectionLocked(ref, collection);
    final views = collectionViewCount(ref, collection);
    final stars = collectionStarCount(ref, collection);
    final credit = collectionCredit(collection);
    final caption = collectionCaption(collection);
    final games = collectionGamesLabel(collection.gameCount);
    return LibraryCatalogRowFrame(
      selected: selected,
      focusDebugLabel: 'collection-row-${collection.slug}',
      semanticsLabel: [
        collection.title,
        if (credit != null) 'by $credit',
        games,
        if (locked) 'Premium',
        if (collection.kind == CollectionKind.book) '$views views',
        if (stars > 0) '$stars stars',
        if (caption != null) caption,
      ].join(', '),
      onSelect: onSelect,
      onOpen: onOpen,
      onContextMenu: onContextMenu,
      builder:
          (context, hovered) => _CatalogColumnsLayout(
            leading: CollectionCoverThumb(
              coverUrl: collection.coverUrl,
              kind: collection.kind,
            ),
            name: Row(
              children: [
                Flexible(
                  child: Text(
                    collection.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: libraryCatalogTitleStyle(selected: selected),
                  ),
                ),
                if (locked) ...[
                  const SizedBox(width: 7),
                  const DesktopLockGlyph(
                    reason: 'Premium collection',
                    size: 12,
                  ),
                ],
                if (caption != null) ...[
                  const SizedBox(width: 10),
                  Expanded(child: LibraryCatalogMutedCell(caption)),
                ],
              ],
            ),
            author: LibraryCatalogMutedCell(credit ?? ''),
            games: LibraryCatalogMutedCell(games),
            views: LibraryCatalogMutedCell(
              collection.kind == CollectionKind.book ? '$views' : '',
            ),
            trailing: CollectionStarButton(collection: collection),
          ),
    );
  }
}
