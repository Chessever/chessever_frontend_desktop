/// What a reader does with a collection: open it in its own tab, put one of
/// its games on the board, unlock it, follow one of its events.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/panes/library_pane.dart'
    show libraryReadOnlyBoardArgs;
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/collections/collection_text.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';

/// The provenance a board tab carries for a game opened from a collection.
/// It is what keeps the game from being copied, saved or exported there.
const DesktopAccessContext collectionAccessContext = DesktopAccessContext(
  feature: DesktopFeature.collection,
  action: DesktopAction.openContent,
  origin: DesktopDiscoveryOrigin.collection,
);

/// Whether [context] says a game was opened from a published collection.
bool isCollectionProvenance(DesktopAccessContext? context) =>
    context?.origin == DesktopDiscoveryOrigin.collection;

/// The collection an opened-collection tab shows.
@immutable
class CollectionWorkspaceArgs {
  const CollectionWorkspaceArgs({required this.slug, required this.title});

  final String slug;
  final String title;
}

final collectionWorkspaceArgsByTabIdProvider =
    StateProvider<Map<String, CollectionWorkspaceArgs>>(
      (_) => const <String, CollectionWorkspaceArgs>{},
    );

/// Opens [slug] in its own tab, or brings forward the tab that already
/// shows it.
String openCollectionWorkspaceTab(
  WidgetRef ref, {
  required String slug,
  required String title,
  String? subtitle,
}) {
  final tabs = ref.read(desktopTabsProvider);
  final argsByTabId = ref.read(collectionWorkspaceArgsByTabIdProvider);
  final existing = tabs.tabs.firstWhereOrNull(
    (tab) =>
        tab.kind == TabKind.collectionWorkspace &&
        argsByTabId[tab.id]?.slug == slug,
  );
  if (existing != null) {
    ref.read(desktopTabsProvider.notifier).activate(existing.id);
    return existing.id;
  }
  final tabId = ref
      .read(desktopTabsProvider.notifier)
      .open(
        TabKind.collectionWorkspace,
        title: title,
        subtitle: subtitle ?? 'Collection',
        reuseExisting: false,
      );
  ref.read(collectionWorkspaceArgsByTabIdProvider.notifier).update((current) {
    return <String, CollectionWorkspaceArgs>{
      ...current,
      tabId: CollectionWorkspaceArgs(slug: slug, title: title),
    };
  });
  return tabId;
}

/// Opens [collection] in its own tab.
String openCollectionTab(WidgetRef ref, Collection collection) =>
    openCollectionWorkspaceTab(
      ref,
      slug: collection.slug,
      title: collection.title,
      subtitle: collectionKindLabel(collection.kind),
    );

/// Puts [row] on the board. [displayed] is the list the reader was looking
/// at, in its order: the board's previous and next walk exactly that. The
/// board replays each game's text as it was published.
void openCollectionGame(
  WidgetRef ref, {
  required String collectionTitle,
  required List<CollectionGame> games,
  required SavedAnalysis row,
  required List<SavedAnalysis> displayed,
  String? initialFen,
}) {
  final pgnById = {for (final game in games) game.id: game.pgn};
  openBoardGameTab(
    ref,
    libraryReadOnlyBoardArgs(
      row,
      databaseTitle: collectionTitle,
      displayed: displayed,
      sourcePgnById: pgnById,
      initialFen: initialFen,
      accessContext: collectionAccessContext,
    ),
    reuseExisting: false,
  );
}

/// How long each re-read waits for a purchase to reach the server. About
/// thirty-five seconds in all, as the phone app gives it.
const List<Duration> kCollectionPremiumConfirmWaits = [
  Duration.zero,
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
  Duration(seconds: 8),
  Duration(seconds: 9),
];

/// Slugs whose Premium is being confirmed right now, so the page can say so.
final collectionConfirmingProvider = StateProvider<Set<String>>(
  (_) => const <String>{},
);

/// Re-reads [slug] until the server reports it open for this account, each
/// read asking it to judge anew. True once it is open (the games and players
/// are then re-read too); false when every wait passed and it is still
/// locked.
Future<bool> confirmCollectionPremium(
  WidgetRef ref,
  String slug, {
  List<Duration> waits = kCollectionPremiumConfirmWaits,
}) async {
  final reader = ref.read(collectionsReaderProvider);
  final confirming = ref.read(collectionConfirmingProvider.notifier);
  confirming.update((current) => {...current, slug});
  try {
    for (final wait in waits) {
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      final release = reader.holdFreshAccess(slug);
      try {
        ref.invalidate(collectionDetailProvider(slug));
        final detail = await ref.read(collectionDetailProvider(slug).future);
        if (!(detail.contentLocked ?? false)) {
          ref.invalidate(collectionGamesProvider(slug));
          ref.invalidate(collectionPlayersProvider(slug));
          return true;
        }
      } catch (_) {
        // A failed read is one more wait, not an answer.
      } finally {
        release();
      }
    }
    return false;
  } finally {
    confirming.update((current) => {...current}..remove(slug));
  }
}

/// The unlock press on a locked collection: the membership dialog, then the
/// confirm loop once it reports Premium.
Future<void> unlockCollection(
  BuildContext context,
  WidgetRef ref,
  Collection collection,
) async {
  final premium = await showDesktopPremiumPaywall(
    context,
    surface: switch (collection.kind) {
      CollectionKind.book => 'collection_books',
      CollectionKind.event => 'collection_events',
      CollectionKind.analysis => 'collection_analysis',
    },
  );
  if (!premium || !context.mounted) return;
  final opened = await confirmCollectionPremium(ref, collection.slug);
  if (opened || !context.mounted) return;
  showDesktopToast(
    context,
    "Couldn't confirm your Premium just now.",
    error: true,
    actionLabel: 'Try again',
    onAction: () => unawaited(unlockCollection(context, ref, collection)),
  );
}

/// Whether [event] leads somewhere this app can open.
bool collectionEventOpens(CollectionEventRef event) => switch (event
    .open
    ?.kind) {
  CollectionEventOpenKind.broadcast ||
  CollectionEventOpenKind.collection => true,
  _ => false,
};

/// Follows one of a collection's bound events: a broadcast opens its event
/// tab, an event collection opens as a collection.
Future<void> openCollectionEvent(
  BuildContext context,
  WidgetRef ref,
  CollectionEventRef event,
) async {
  final open = event.open;
  if (open == null) return;
  switch (open.kind) {
    case CollectionEventOpenKind.collection:
      final slug = open.slug;
      if (slug == null) return;
      openCollectionWorkspaceTab(
        ref,
        slug: slug,
        title: event.title,
        subtitle: collectionKindLabel(CollectionKind.event),
      );
    case CollectionEventOpenKind.broadcast:
      final id = open.groupBroadcastId;
      if (id == null) return;
      final container = ProviderScope.containerOf(context, listen: false);
      final opened = await DesktopDeepLinkRouter.instance.handle(
        Uri.https('chessever.com', '/broadcast/$id'),
        container,
      );
      if (!opened && context.mounted) {
        showDesktopToast(context, "Couldn't open this event", error: true);
      }
    default:
      break;
  }
}
