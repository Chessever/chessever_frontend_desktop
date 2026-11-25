import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';

/// The request the Toby panel asks admission for. Reading Toby's prediction
/// is Premium on every edition, whatever the board shows.
const DesktopAccessContext tobyPredictionAccessContext = DesktopAccessContext(
  feature: DesktopFeature.tobyPrediction,
  action: DesktopAction.view,
  origin: DesktopDiscoveryOrigin.localFile,
);

/// Whether the current membership may read Toby's prediction. Render-safe:
/// it never opens a paywall. The panel reads it to decide whether to ask
/// for readings at all, and the reading loop reads it once to tell a
/// membership the client trusts from one it does not.
final tobyPredictionAccessProvider = Provider<DesktopAccessDecision>(
  (ref) => readDesktopAccess(ref.watch, tobyPredictionAccessContext),
);

/// Admission for opening the panel (an explicit tap or key). Returns true
/// when the reader may see Toby's prediction now. Otherwise opens the
/// window's Premium prompt (sign in, upgrade or Retry, whichever the
/// membership calls for; the Mac App Store edition offers store plans) and
/// returns false: the caller must not expand. [resume] runs once after a
/// verified purchase, so it can expand the panel the reader asked for.
bool admitTobyPrediction(
  ProviderContainer container, {
  required String surface,
  DesktopAccessResume? resume,
}) => admitDesktopAction(
  container,
  tobyPredictionAccessContext,
  surface: surface,
  resume: resume,
);
