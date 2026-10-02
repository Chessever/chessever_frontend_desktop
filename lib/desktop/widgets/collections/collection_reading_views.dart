/// The reading views of a collection: its About page, the table of contents
/// a locked one shows, its players and the events it is bound to.
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/library_pane.dart'
    show LibraryEmptyState;
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/desktop/widgets/collections/collection_catalog_row.dart';
import 'package:chessever/desktop/widgets/collections/collection_text.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_locked_content.dart';
import 'package:chessever/desktop/widgets/library/library_catalog_row.dart';
import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/theme/app_theme.dart';

/// The Library's small centred spinner.
class CollectionLoading extends StatelessWidget {
  const CollectionLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}

/// Something could not be loaded: what, and a way to ask again.
class CollectionLoadError extends StatelessWidget {
  const CollectionLoadError({
    super.key,
    required this.title,
    required this.onRetry,
    this.error,
  });

  final String title;
  final VoidCallback onRetry;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final request = error;
    if (isCollectionsNotAvailable(request)) {
      return const LibraryEmptyState(
        icon: Icons.auto_stories_outlined,
        title: 'Collections are not available yet',
        message:
            'This version cannot reach the collections catalog. '
            'Update ChessEver and try again.',
      );
    }
    final unavailable =
        request is CollectionsRequestException &&
        request.isAccessCheckUnavailable;
    return LibraryEmptyState(
      icon: Icons.cloud_off_rounded,
      title:
          unavailable ? "Couldn't check your Premium access just now." : title,
      message: 'Check your connection, then try again.',
      action: DesktopDialogButton(
        label: 'Try again',
        icon: Icons.refresh_rounded,
        onPress: onRetry,
      ),
    );
  }
}

/// The unlock control of a locked collection, with the confirm line while a
/// purchase is being checked.
class CollectionUnlockButton extends ConsumerWidget {
  const CollectionUnlockButton({super.key, required this.collection});

  final Collection collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final confirming = ref
        .watch(collectionConfirmingProvider)
        .contains(collection.slug);
    if (confirming) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(kPrimaryColor),
            ),
          ),
          SizedBox(width: 10),
          Text(
            'Confirming your Premium…',
            style: TextStyle(color: kWhiteColor70, fontSize: 12.5),
          ),
        ],
      );
    }
    return DesktopDialogButton(
      label: collectionUnlockLabel(collection),
      icon: Icons.lock_open_rounded,
      tone: DesktopDialogButtonTone.primary,
      onPress: () => unawaited(unlockCollection(context, ref, collection)),
    );
  }
}

/// What a locked collection shows in place of its games: the unlock control,
/// then its table of contents (each chapter or round with its game count),
/// or, when it has no sections, the first of its players.
class CollectionLockedContents extends ConsumerWidget {
  const CollectionLockedContents({super.key, required this.collection});

  final Collection collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void unlock() => unawaited(unlockCollection(context, ref, collection));
    final rows = <Widget>[];
    void addSection(CollectionSection section, {required bool child}) {
      final isPart =
          section.kind == CollectionSectionKind.part ||
          section.children.isNotEmpty;
      if (isPart) {
        rows.add(LibraryCatalogSectionLabel(label: _sectionTitle(section)));
        for (final chapter in section.children) {
          addSection(chapter, child: true);
        }
        if (section.gameCount <= 0) return;
      }
      rows.add(
        _LockedSectionRow(
          title: isPart ? 'Games in this part' : _sectionTitle(section),
          games: collectionGamesLabel(section.gameCount),
          indented: child,
          onTap: unlock,
        ),
      );
    }

    for (final section in collection.sections) {
      addSection(section, child: false);
    }

    final names = collection.players;
    final shown = names.take(6).join(' · ');
    final more = names.length - 6;
    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: CollectionUnlockButton(collection: collection),
        ),
        const SizedBox(height: 16),
        if (rows.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kDividerColor),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          )
        else if (names.isNotEmpty)
          Text(
            more > 0 ? '$shown · $more more' : shown,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
      ],
    );
  }
}

String _sectionTitle(CollectionSection section) {
  final title = section.title?.trim() ?? '';
  if (title.isEmpty) return section.label;
  return section.label.isEmpty ? title : '${section.label}: $title';
}

class _LockedSectionRow extends StatefulWidget {
  const _LockedSectionRow({
    required this.title,
    required this.games,
    required this.indented,
    required this.onTap,
  });

  final String title;
  final String games;
  final bool indented;
  final VoidCallback onTap;

  @override
  State<_LockedSectionRow> createState() => _LockedSectionRowState();
}

class _LockedSectionRowState extends State<_LockedSectionRow>
    with DeferredPointerStateMixin<_LockedSectionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${widget.title}, ${widget.games}, Premium',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              height: kLibraryCatalogRowHeight,
              padding: EdgeInsets.only(
                left: widget.indented ? 28 : 12,
                right: 12,
              ),
              decoration: BoxDecoration(
                color:
                    _hovered
                        ? kBlack3Color.withValues(alpha: 0.72)
                        : Colors.transparent,
                border: Border(
                  bottom: BorderSide(
                    color: kDividerColor.withValues(alpha: 0.72),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: libraryCatalogTitleStyle(selected: false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  LibraryCatalogMutedCell(widget.games),
                  const SizedBox(width: 12),
                  const DesktopLockGlyph(
                    reason: 'Premium collection',
                    size: 12,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A collection's About page: cover, credits, edition and its prose, then
/// the events it is bound to. Prose stays at a reading width.
class CollectionAboutView extends ConsumerWidget {
  const CollectionAboutView({
    super.key,
    required this.collection,
    required this.locked,
    required this.playerCount,
    required this.onShowAuthor,
  });

  final Collection collection;
  final bool locked;

  /// Null until the players are known.
  final int? playerCount;

  /// Shows the catalog narrowed to this collection's author.
  final VoidCallback onShowAuthor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBook = collection.kind == CollectionKind.book;
    final author = collection.author?.trim() ?? '';
    final annotator = collection.annotator?.trim() ?? '';
    final edition = collectionEdition(collection);
    final where = [
      if (collection.location?.trim().isNotEmpty ?? false)
        collection.location!.trim(),
      if (collectionDateRange(collection.dateStart, collection.dateEnd)
          case final dates?)
        dates,
    ].join(' · ');
    final contents = [
      collectionGamesLabel(collection.gameCount),
      if (playerCount != null && playerCount! > 0)
        playerCount == 1 ? '1 player' : '$playerCount players',
    ].join(' · ');
    final summary = switch (collection.kind) {
      CollectionKind.event => 'Selected games from ${collection.title}.',
      CollectionKind.analysis =>
        'Selected game analysis from ${collection.title}.',
      CollectionKind.book => null,
    };

    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (collection.coverUrl?.trim().isNotEmpty ?? false) ...[
                      _AboutCover(
                        url: collection.coverUrl!.trim(),
                        portrait: isBook,
                      ),
                      const SizedBox(width: 16),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            collection.title,
                            style: const TextStyle(
                              color: kWhiteColor,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              height: 1.2,
                            ),
                          ),
                          if (collection.subtitle?.trim().isNotEmpty ??
                              false) ...[
                            const SizedBox(height: 4),
                            Text(
                              collection.subtitle!.trim(),
                              style: const TextStyle(
                                color: kWhiteColor70,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          if (author.isNotEmpty)
                            _CreditLink(
                              label: 'by $author',
                              tooltip: "Show $author's collections",
                              onTap: onShowAuthor,
                            )
                          else if (annotator.isNotEmpty)
                            _AboutFact('Annotated by $annotator'),
                          if (author.isNotEmpty &&
                              annotator.isNotEmpty &&
                              annotator != author)
                            _AboutFact('Annotated by $annotator'),
                          if (isBook && edition != null) _AboutFact(edition),
                          if (!isBook && where.isNotEmpty) _AboutFact(where),
                          if (!locked) _AboutFact(contents),
                        ],
                      ),
                    ),
                  ],
                ),
                if (locked) ...[
                  const SizedBox(height: 16),
                  CollectionUnlockButton(collection: collection),
                ],
                if (summary != null) _AboutProse(heading: null, text: summary),
                _AboutProse(
                  heading: isBook ? 'About this collection' : null,
                  text: collection.about,
                ),
                _AboutProse(heading: 'Foreword', text: collection.foreword),
                _AboutProse(
                  heading: 'About the author',
                  text: collection.authorBio,
                ),
                _AboutProse(
                  heading: 'About the annotator',
                  text: collection.annotatorBio,
                ),
                if (collection.events.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  const _AboutHeading('Events'),
                  const SizedBox(height: 8),
                  _BoundList(
                    children: [
                      for (final event in collection.events)
                        _BoundEventRow(event: event),
                    ],
                  ),
                ],
                if (collection.kind == CollectionKind.event)
                  _BooksAboutEvent(collectionId: collection.id),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AboutCover extends StatelessWidget {
  const _AboutCover({required this.url, required this.portrait});

  final String url;
  final bool portrait;

  @override
  Widget build(BuildContext context) {
    final width = portrait ? 84.0 : 176.0;
    final height = portrait ? 126.0 : 99.0;
    final blank = Container(width: width, height: height, color: kBlack2Color);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: portrait ? BoxFit.contain : BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, _) => blank,
        errorWidget: (_, _, _) => blank,
      ),
    );
  }
}

class _AboutFact extends StatelessWidget {
  const _AboutFact(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        text,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _AboutHeading extends StatelessWidget {
  const _AboutHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _AboutProse extends StatelessWidget {
  const _AboutProse({required this.heading, required this.text});

  final String? heading;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final paragraphs = collectionParagraphs(text);
    if (paragraphs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (heading != null) ...[
            _AboutHeading(heading!),
            const SizedBox(height: 8),
          ],
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
    );
  }
}

/// The author credit, which leads to that author's collections.
class _CreditLink extends StatefulWidget {
  const _CreditLink({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_CreditLink> createState() => _CreditLinkState();
}

class _CreditLinkState extends State<_CreditLink>
    with DeferredPointerStateMixin<_CreditLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Text(
              widget.label,
              style: TextStyle(
                color: _hovered ? kPrimaryColor : kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BoundList extends StatelessWidget {
  const _BoundList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// One event a collection is bound to. It opens when the app can resolve it;
/// otherwise it stays a plain line saying what the collection covers.
class _BoundEventRow extends ConsumerWidget {
  const _BoundEventRow({required this.event});

  final CollectionEventRef event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opens = collectionEventOpens(event);
    final detail = [
      if (event.location?.trim().isNotEmpty ?? false) event.location!.trim(),
      if (collectionDateRange(event.dateStart, event.dateEnd) case final d?) d,
      if (event.note?.trim().isNotEmpty ?? false) event.note!.trim(),
    ].join(' · ');
    Widget cells(bool selected) => Row(
      children: [
        const Icon(
          Icons.emoji_events_outlined,
          size: 15,
          color: kLightGreyColor,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            event.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: libraryCatalogTitleStyle(selected: selected),
          ),
        ),
        if (detail.isNotEmpty) ...[
          const SizedBox(width: 10),
          Expanded(child: LibraryCatalogMutedCell(detail)),
        ],
        if (opens)
          const Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: kLightGreyColor,
          ),
      ],
    );
    if (!opens) {
      return Container(
        height: kLibraryCatalogRowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: kDividerColor.withValues(alpha: 0.72)),
          ),
        ),
        child: cells(false),
      );
    }
    void open() => unawaited(openCollectionEvent(context, ref, event));
    return LibraryCatalogRowFrame(
      selected: false,
      semanticsLabel: 'Open ${event.title}',
      focusDebugLabel: 'collection-event-${event.linkId}',
      // A link, not a selection: one click follows it.
      onSelect: open,
      onOpen: open,
      builder: (context, hovered) => cells(false),
    );
  }
}

/// The published collections about an event collection, with the team's note
/// for each. Nothing is drawn while they load or when there are none.
class _BooksAboutEvent extends ConsumerWidget {
  const _BooksAboutEvent({required this.collectionId});

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books =
        ref
            .watch(
              collectionBooksForEventProvider(
                CollectionEventAnchors(collections: [collectionId]),
              ),
            )
            .valueOrNull ??
        const <Collection>[];
    if (books.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AboutHeading(books.length == 1 ? 'Collection' : 'Collections'),
          const SizedBox(height: 8),
          _BoundList(
            children: [
              for (final book in books)
                CollectionCatalogRow(
                  collection: book,
                  selected: false,
                  onSelect: () => openCollectionTab(ref, book),
                  onOpen: () => openCollectionTab(ref, book),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Everyone who played in a collection, most games first, as a Library
/// table. A double click (or Enter) shows that player's games.
class CollectionPlayersTable extends StatefulWidget {
  const CollectionPlayersTable({
    super.key,
    required this.players,
    required this.onShowGames,
  });

  final List<CollectionPlayer> players;
  final ValueChanged<CollectionPlayer> onShowGames;

  @override
  State<CollectionPlayersTable> createState() => _CollectionPlayersTableState();
}

class _CollectionPlayersTableState extends State<CollectionPlayersTable> {
  String? _selectedKey;

  static const double _rank = 34;
  static const double _number = 54;

  @override
  Widget build(BuildContext context) {
    Widget header(String label, {double? width, bool end = true}) {
      final text = Text(
        label,
        textAlign: end ? TextAlign.right : TextAlign.left,
        style: kLibraryCatalogHeaderStyle,
      );
      return width == null
          ? Expanded(child: text)
          : SizedBox(width: width, child: text);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Container(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            LibraryCatalogHeaderStrip(
              child: Row(
                children: [
                  header('#', width: _rank),
                  const SizedBox(width: 12),
                  header('PLAYER', end: false),
                  header('ELO', width: _number),
                  header('GAMES', width: _number + 8),
                  header('WON', width: _number),
                  header('DRAWN', width: _number),
                  header('LOST', width: _number),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                physics: const DesktopScrollPhysics(),
                padding: EdgeInsets.zero,
                itemExtent: 44,
                itemCount: widget.players.length,
                itemBuilder: (context, index) {
                  final player = widget.players[index];
                  return _PlayerRow(
                    rank: index + 1,
                    player: player,
                    selected: player.key == _selectedKey,
                    rankWidth: _rank,
                    numberWidth: _number,
                    onSelect: () => setState(() => _selectedKey = player.key),
                    onOpen: () => widget.onShowGames(player),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerRow extends StatefulWidget {
  const _PlayerRow({
    required this.rank,
    required this.player,
    required this.selected,
    required this.rankWidth,
    required this.numberWidth,
    required this.onSelect,
    required this.onOpen,
  });

  final int rank;
  final CollectionPlayer player;
  final bool selected;
  final double rankWidth;
  final double numberWidth;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  State<_PlayerRow> createState() => _PlayerRowState();
}

class _PlayerRowState extends State<_PlayerRow>
    with DeferredPointerStateMixin<_PlayerRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    Widget number(String value, {double extra = 0}) => SizedBox(
      width: widget.numberWidth + extra,
      child: Text(
        value,
        textAlign: TextAlign.right,
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${player.name}, ${collectionGamesLabel(player.games)}, '
          '${player.wins} won, ${player.draws} drawn, ${player.losses} lost',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            onDoubleTap: widget.onOpen,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: librarySelectedRowDecoration(
                selected: widget.selected,
                hovered: _hovered,
              ),
              padding: const EdgeInsets.fromLTRB(7, 0, 10, 0),
              child: Row(
                children: [
                  SizedBox(
                    width: widget.rankWidth,
                    child: Text(
                      '${widget.rank}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LibraryTablePlayerCell(
                      name: player.name,
                      federation: player.fed ?? '',
                      fideId: int.tryParse(player.fideId ?? ''),
                      title: player.title ?? '',
                      abbreviate: false,
                    ),
                  ),
                  number(player.bestElo == null ? '' : '${player.bestElo}'),
                  number('${player.games}', extra: 8),
                  number('${player.wins}'),
                  number('${player.draws}'),
                  number('${player.losses}'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
