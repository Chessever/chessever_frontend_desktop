import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';

/// Where a game was discovered, when it was discovered through a smart
/// collection. The same game can be free through an ordinary broadcast and
/// gated through a smart collection, so this travels with every content
/// action taken from the smart-event surface.
@immutable
class SmartCollectionProvenance {
  const SmartCollectionProvenance({
    required this.criteriaKey,
    required this.displayName,
  });

  /// `SmartEventRequest.criteriaKey` of the collection.
  final String criteriaKey;
  final String displayName;

  @override
  bool operator ==(Object other) =>
      other is SmartCollectionProvenance &&
      other.criteriaKey == criteriaKey &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(criteriaKey, displayName);
}

/// Game content actions a smart collection exposes. Browsing the collection,
/// editing its criteria, its card and saving it are deliberately absent: those
/// are free and never pass through the gate.
enum SmartCollectionContentAction {
  /// Open the full game on a board.
  openGame,

  /// Step through a preview (a static preview is free).
  previewNavigate,

  /// Copy, share, export or save the game through its context menu.
  gameContextMenu,
}

/// Decides one content action. Called only on an explicit user action; it may
/// show a paywall in [context] and resolves `true` when the action may run.
/// It must resolve before any expensive work (fetch, engine, board open).
typedef SmartCollectionContentGate =
    Future<bool> Function(
      BuildContext context,
      SmartCollectionProvenance provenance,
      SmartCollectionContentAction action,
    );

/// The gate every smart-collection content action passes.
///
/// Evaluates the request against the live membership and, when it is denied,
/// presents the paywall in the window that owns [context]. It resolves `true`
/// only when a re-read of the membership admits the action, never on the
/// dialog's own say-so. Nothing in the smart-event surface calls a content
/// action without going through it.
final smartCollectionContentGateProvider = Provider<SmartCollectionContentGate>(
  (ref) => (context, provenance, action) {
    return requireDesktopAction(
      ProviderScope.containerOf(context, listen: false),
      smartCollectionAccessContext(action),
      surface: 'smart_collection',
    );
  },
);

/// The access request a smart-collection content action makes. Provenance,
/// not game identity, decides: the same game stays free through its broadcast.
DesktopAccessContext smartCollectionAccessContext(
  SmartCollectionContentAction action,
) {
  return DesktopAccessContext(
    feature: DesktopFeature.smartCollection,
    origin: DesktopDiscoveryOrigin.smartCollection,
    action: switch (action) {
      SmartCollectionContentAction.openGame => DesktopAction.openContent,
      SmartCollectionContentAction.previewNavigate =>
        DesktopAction.previewNavigate,
      SmartCollectionContentAction.gameContextMenu => DesktopAction.copy,
    },
  );
}

/// Synchronous view for affordances that cannot await (whether a card offers
/// its context menu at all). It stays open: each menu item is gated when it is
/// chosen by the card's own access context, so the menu remains discoverable
/// and rendering it never opens a paywall.
final smartCollectionContextMenuAllowedProvider =
    Provider.family<bool, SmartCollectionProvenance>((ref, provenance) => true);
