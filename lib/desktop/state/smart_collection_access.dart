import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

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

/// The seam the freemium policy layer overrides.
///
/// `main` has no entitlement evaluator yet (the desktop subscription stub
/// keeps every gate open), so the default allows. The policy PR replaces this
/// provider; nothing in the smart-event surface calls a content action without
/// going through it.
final smartCollectionContentGateProvider = Provider<SmartCollectionContentGate>(
  (ref) => (context, provenance, action) async => true,
);

/// Synchronous view of the same decision for affordances that cannot await
/// (whether a card offers its context menu at all). Defaults to the open
/// stub; the policy PR overrides it alongside the gate.
final smartCollectionContextMenuAllowedProvider =
    Provider.family<bool, SmartCollectionProvenance>((ref, provenance) => true);
