import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_collection_game_access.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';

/// The free collection table is visible while its historical PGN preview
/// waits for the same admission as opening that game on the board.
class CollectionPreviewAccessGate extends ConsumerWidget {
  const CollectionPreviewAccessGate({
    super.key,
    required this.row,
    required this.builder,
  });

  final SavedAnalysis? row;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = row;
    if (selected == null || !ref.watch(desktopPastEventAccessEnabledProvider)) {
      return builder(context);
    }
    final classified = ref.watch(desktopCollectionGameAccessProvider(selected));
    final access = classified.valueOrNull;
    final decision =
        access == null
            ? DesktopAccessDecision(
              classified.hasError
                  ? DesktopAccess.temporarilyUnavailable
                  : DesktopAccess.checking,
              DesktopAccessReason.entitlementChecking,
            )
            : ref.watch(desktopAccessDecisionProvider(access));
    if (decision.isAllowed) return builder(context);
    return DesktopAccessLockedSurface(
      decision: decision,
      accessContext: access ?? desktopPastEventOpenContext,
      surface: 'collection_preview',
    );
  }
}
