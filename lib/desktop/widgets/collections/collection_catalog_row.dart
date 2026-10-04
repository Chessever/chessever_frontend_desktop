import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/state/collections_catalog.dart';
import 'package:chessever/desktop/widgets/collections/collection_text.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_icon.dart';
import 'package:chessever/desktop/widgets/desktop_locked_content.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/library/library_catalog_row.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/svg_asset.dart';

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

/// Stars or unstars a collection: the phone's star as a bare glyph, with the
/// public star count before it when there is one.
///
/// A catalog row lays the count out itself, in its own column, and asks for
/// the star alone ([showCount] false).
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
    final star = _StarGlyphButton(
      starred: starred,
      onPress: () => unawaited(pressCollectionStar(context, collection)),
    );
    if (!showCount) return star;
    final count = collectionStarCount(ref, collection);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (count > 0) ...[
          LibraryCatalogMutedCell('$count'),
          const SizedBox(width: CollectionCatalogColumns.starGap),
        ],
        star,
      ],
    );
  }
}

/// Whether [event] presses the focused control: Enter or Space.
bool _isActivation(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  final key = event.logicalKey;
  return key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space;
}

/// One of the phone's line glyphs (the outline star, the chevron) in exactly
/// [color].
///
/// Those assets are stroked at 70% opacity, so a plain tint comes out dimmer
/// than the colour asked for. The filter replaces the colour and scales the
/// art's own alpha back to full before [color]'s applies.
class _LineGlyph extends StatelessWidget {
  const _LineGlyph(this.asset, {required this.size, required this.color});

  final String asset;
  final double size;
  final Color color;

  static const double _strokeOpacity = 0.7;

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(<double>[
        0, 0, 0, 0, color.r * 255, //
        0, 0, 0, 0, color.g * 255, //
        0, 0, 0, 0, color.b * 255, //
        0, 0, 0, color.a / _strokeOpacity, 0, //
      ]),
      child: DesktopIcon(asset, size: size),
    );
  }
}

/// A tap that takes the pointer as soon as it lands. A catalog row waits to
/// tell a click from a double click; the star on it answers at once.
class _EagerTapGestureRecognizer extends TapGestureRecognizer {
  _EagerTapGestureRecognizer({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// The star itself: the phone's gold star while starred, its outline
/// otherwise. A bare glyph in every state; hovering brightens the outline
/// and a press dips it, nothing is drawn behind it.
class _StarGlyphButton extends StatefulWidget {
  const _StarGlyphButton({required this.starred, required this.onPress});

  final bool starred;
  final VoidCallback onPress;

  @override
  State<_StarGlyphButton> createState() => _StarGlyphButtonState();
}

class _StarGlyphButtonState extends State<_StarGlyphButton>
    with
        SingleTickerProviderStateMixin,
        DeferredPointerStateMixin<_StarGlyphButton> {
  static const double _glyphSize = 16;

  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1,
    end: 0.97,
  ).animate(
    CurvedAnimation(
      parent: _press,
      curve: Curves.easeOut,
      // Played backwards, so this eases out of the dip as well.
      reverseCurve: Curves.easeIn,
    ),
  );

  bool _hovered = false;
  bool _focused = false;
  bool _held = false;

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _down() {
    _held = true;
    if (!_still) _press.forward();
  }

  void _release() {
    _held = false;
    if (_still) return;
    // A quick click still dips all the way before it comes back.
    _press.forward().whenCompleteOrCancel(() {
      if (mounted && !_held) _press.reverse();
    });
  }

  void _activate() {
    _down();
    _release();
    widget.onPress();
  }

  @override
  Widget build(BuildContext context) {
    final tooltip = widget.starred ? 'Unstar collection' : 'Star collection';
    final Widget glyph =
        widget.starred
            // Gold, as the phone draws it.
            ? const DesktopIcon(SvgAsset.starFilledIcon, size: _glyphSize)
            : TweenAnimationBuilder<Color?>(
              tween: ColorTween(
                end: _hovered || _focused ? kWhiteColor : kWhiteColor70,
              ),
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              builder:
                  (context, color, _) => _LineGlyph(
                    SvgAsset.starIcon,
                    size: _glyphSize,
                    color: color ?? kWhiteColor70,
                  ),
            );
    return DesktopTooltip(
      message: tooltip,
      // The star stands at a right edge: the tip is set from its right, so
      // it never has to be pushed back in from the edge of the window.
      tipAnchor: Alignment.bottomRight,
      childAnchor: Alignment.topRight,
      child: Focus(
        debugLabel: 'collection-star',
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (_, event) {
          if (!_isActivation(event)) return KeyEventResult.ignored;
          _activate();
          return KeyEventResult.handled;
        },
        child: Semantics(
          button: true,
          label: tooltip,
          onTap: widget.onPress,
          excludeSemantics: true,
          child: CursorAware(
            mode: CursorMode.hover,
            child: MouseRegion(
              onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
              onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  _EagerTapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _EagerTapGestureRecognizer
                      >(
                        () => _EagerTapGestureRecognizer(debugOwner: this),
                        (recognizer) =>
                            recognizer
                              ..onTapDown = ((_) => _down())
                              ..onTapUp = ((_) => _release())
                              ..onTapCancel = _release
                              ..onTap = widget.onPress,
                      ),
                },
                child: SizedBox.square(
                  dimension: CollectionCatalogColumns.starWidth,
                  child: Center(
                    child: ScaleTransition(scale: _scale, child: glyph),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The star press behind every collection star, with its feedback.
///
/// The container is taken before the first wait: a starred row moves to the
/// top of the catalog, and the widget that was pressed is gone by then.
Future<void> pressCollectionStar(
  BuildContext context,
  Collection collection,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final outcome = await toggleCollectionStar(container, collection);
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

/// Which of the catalog's columns fit [width], and how wide each one is.
///
/// Every column is one [gutter] from the next. Text columns are set from
/// their left edge and counts from their right, and each header label sits
/// on the edge its cells do.
@immutable
class CollectionCatalogColumns {
  const CollectionCatalogColumns._({
    required this.showAuthor,
    required this.showViews,
  });

  factory CollectionCatalogColumns.forWidth(double width) =>
      CollectionCatalogColumns._(
        showAuthor: width >= 600,
        showViews: width >= 700,
      );

  final bool showAuthor;
  final bool showViews;

  static const double gutter = 16;
  static const double coverWidth = 27;
  static const double authorWidth = 160;
  static const double gamesWidth = 72;
  static const double viewsWidth = 60;

  /// The star count's own slot: every count ends on its right edge, and a
  /// row without stars leaves it empty instead of closing it.
  static const double starCountWidth = 56;

  /// The star's slot, which is also what takes the pointer. The glyph sits
  /// in the middle of it, so the stars of every row form one line.
  static const double starWidth = 28;

  /// Between a count and its star's slot. They read as one value: the glyph
  /// is inset in its slot, which makes the visible distance 8.
  static const double starGap = 2;
}

class _CatalogColumnsLayout extends StatelessWidget {
  const _CatalogColumnsLayout({
    required this.leading,
    required this.name,
    required this.author,
    required this.games,
    required this.views,
    required this.stars,
    required this.star,
    this.stretch = false,
  });

  final Widget leading;
  final Widget name;
  final Widget author;
  final Widget games;
  final Widget views;
  final Widget stars;
  final Widget star;

  /// Cells take the full height of the line: a header cell is pressable all
  /// over, not only on its label.
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    const gutter = SizedBox(width: CollectionCatalogColumns.gutter);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = CollectionCatalogColumns.forWidth(constraints.maxWidth);
        return Row(
          crossAxisAlignment:
              stretch ? CrossAxisAlignment.stretch : CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: CollectionCatalogColumns.coverWidth,
              child: leading,
            ),
            gutter,
            Expanded(child: name),
            if (columns.showAuthor) ...[
              gutter,
              SizedBox(
                width: CollectionCatalogColumns.authorWidth,
                child: author,
              ),
            ],
            gutter,
            SizedBox(width: CollectionCatalogColumns.gamesWidth, child: games),
            if (columns.showViews) ...[
              gutter,
              SizedBox(
                width: CollectionCatalogColumns.viewsWidth,
                child: views,
              ),
            ],
            gutter,
            SizedBox(
              width: CollectionCatalogColumns.starCountWidth,
              child: stars,
            ),
            const SizedBox(width: CollectionCatalogColumns.starGap),
            SizedBox(width: CollectionCatalogColumns.starWidth, child: star),
          ],
        );
      },
    );
  }
}

/// The catalog's column headers, on the Library's header strip. A press on
/// one asks for the catalog in that column's order ([onSort]); the column it
/// is sorted by is lit and carries the direction.
class CollectionCatalogHeader extends StatelessWidget {
  const CollectionCatalogHeader({
    super.key,
    required this.sort,
    required this.onSort,
  });

  final CollectionCatalogSort sort;
  final ValueChanged<CollectionSortColumn> onSort;

  @override
  Widget build(BuildContext context) {
    Widget cell(
      CollectionSortColumn column,
      String label, {
      bool end = false,
    }) => _SortHeaderCell(
      column: column,
      label: label,
      alignEnd: end,
      sort: sort,
      onPress: () => onSort(column),
    );
    return LibraryCatalogHeaderStrip(
      child: Padding(
        // A row's cells start after its selection bar.
        padding: const EdgeInsets.only(left: kLibraryCatalogRowBarWidth),
        child: _CatalogColumnsLayout(
          stretch: true,
          leading: const SizedBox.shrink(),
          name: cell(CollectionSortColumn.name, 'COLLECTION'),
          author: cell(CollectionSortColumn.author, 'AUTHOR'),
          games: cell(CollectionSortColumn.games, 'GAMES', end: true),
          views: cell(CollectionSortColumn.views, 'VIEWS', end: true),
          stars: cell(CollectionSortColumn.stars, 'STARS', end: true),
          star: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// One column header as a button. Its label keeps its edge whatever the
/// order: the direction mark goes after a label set from the left and before
/// one set from the right, and an unsorted column keeps no room for it.
class _SortHeaderCell extends StatefulWidget {
  const _SortHeaderCell({
    required this.column,
    required this.label,
    required this.alignEnd,
    required this.sort,
    required this.onPress,
  });

  final CollectionSortColumn column;
  final String label;
  final bool alignEnd;
  final CollectionCatalogSort sort;
  final VoidCallback onPress;

  @override
  State<_SortHeaderCell> createState() => _SortHeaderCellState();
}

class _SortHeaderCellState extends State<_SortHeaderCell>
    with DeferredPointerStateMixin<_SortHeaderCell> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.sort.column == widget.column;
    final ascending = widget.sort.ascending;
    final color =
        active
            ? kWhiteColor
            : (_hovered || _focused ? kWhiteColor70 : kLightGreyColor);
    // The label's line is as tall as the direction mark, with its capitals
    // in the middle of it. A typeface sets its capitals off the centre of
    // its line box, each by its own amount; anchored on the baseline, the
    // label and the mark share a centre on every platform.
    final capitals = (kLibraryCatalogHeaderStyle.fontSize ?? 10.5) * 0.7;
    final label = Flexible(
      child: SizedBox(
        height: _SortMark.size,
        child: Baseline(
          baseline: (_SortMark.size + capitals) / 2,
          baselineType: TextBaseline.alphabetic,
          child: AnimatedDefaultTextStyle(
            // A new order shows at once; only the hover eases.
            key: ValueKey(active),
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            style: DefaultTextStyle.of(
              context,
            ).style.merge(kLibraryCatalogHeaderStyle.copyWith(color: color)),
            child: Text(
              widget.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
    const gap = SizedBox(width: 2);
    final mark = _SortMark(ascending: ascending);
    return Focus(
      debugLabel: 'collection-sort-${widget.column.api}',
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (_, event) {
        if (!_isActivation(event)) return KeyEventResult.ignored;
        widget.onPress();
        return KeyEventResult.handled;
      },
      child: Semantics(
        button: true,
        label: 'Sort by ${widget.column.api}',
        value: active ? (ascending ? 'Ascending' : 'Descending') : null,
        onTap: widget.onPress,
        excludeSemantics: true,
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
            onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPress,
              child: Align(
                alignment:
                    widget.alignEnd
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                child: FFocusedOutline(
                  focused: _focused,
                  style:
                      (style) => style.copyWith(
                        borderRadius: BorderRadius.circular(4),
                      ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (active && widget.alignEnd) ...[mark, gap],
                      label,
                      if (active && !widget.alignEnd) ...[gap, mark],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The direction of the sorted column: the phone's chevron, pointing down
/// for a descending order and turned over for an ascending one.
class _SortMark extends StatelessWidget {
  const _SortMark({required this.ascending});

  final bool ascending;

  static const double size = 14;

  /// The chevron is drawn a little right of the middle of its 21 wide art
  /// board; this brings it back, so it is centred both ways up.
  static const double _drawnOffCentre = 0.4648 / 21;

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: ascending ? 2 : 0,
      child: Transform.translate(
        offset: const Offset(-size * _drawnOffCentre, 0),
        child: const _LineGlyph(
          SvgAsset.arrowDown,
          size: size,
          color: kWhiteColor,
        ),
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
              size: CollectionCatalogColumns.coverWidth,
            ),
            name: CollectionTitleLine(
              title: collection.title,
              caption: caption,
              selected: selected,
              locked: locked,
            ),
            author: LibraryCatalogMutedCell(credit ?? ''),
            games: LibraryCatalogMutedCell(games, textAlign: TextAlign.right),
            views: LibraryCatalogMutedCell(
              collection.kind == CollectionKind.book ? '$views' : '',
              textAlign: TextAlign.right,
            ),
            // A row without stars keeps the slot, so every star stays in line.
            stars: LibraryCatalogMutedCell(
              stars > 0 ? '$stars' : '',
              textAlign: TextAlign.right,
            ),
            star: CollectionStarButton(
              collection: collection,
              showCount: false,
            ),
          ),
    );
  }
}

/// A row's title with what follows it on the same line: the Premium lock,
/// then a quiet caption. One text, so the title takes the room it needs and
/// the caption the rest, and the whole line ends in one ellipsis.
class CollectionTitleLine extends StatelessWidget {
  const CollectionTitleLine({
    super.key,
    required this.title,
    this.caption,
    this.selected = false,
    this.locked = false,
  });

  final String title;
  final String? caption;
  final bool selected;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final note = caption?.trim() ?? '';
    return Text.rich(
      TextSpan(
        style: libraryCatalogTitleStyle(selected: selected),
        children: [
          TextSpan(text: title),
          if (locked)
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsets.only(left: 7),
                child: DesktopLockGlyph(reason: 'Premium collection', size: 12),
              ),
            ),
          if (note.isNotEmpty)
            TextSpan(
              text: '   $note',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
