import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/library/utils/saved_analysis_converters.dart';

/// Public collections can contain historical event games. The collection
/// provenance remains attached so no purchase unlocks copying its contents.
const desktopCollectionGameAccess = DesktopAccessContext(
  feature: DesktopFeature.collection,
  action: DesktopAction.openContent,
  origin: DesktopDiscoveryOrigin.collection,
);

final desktopCollectionGameAccessProvider = FutureProvider.autoDispose
    .family<DesktopAccessContext, SavedAnalysis>((ref, row) {
      return resolveDesktopGameEventAccess(
        ref.container,
        game: savedAnalysisToCardGame(row),
        access: desktopCollectionGameAccess,
      );
    });
