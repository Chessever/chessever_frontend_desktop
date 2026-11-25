import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// Toby Predicts in the shared access policy. Toby's prediction is free
/// on every edition, for guests too: Gamebase decides who may read it (its
/// next-move access setting), so the client never gates the tab or a
/// request, and nothing in the app asks the policy before reading. The
/// context names the rule, so it can be read (and tested) like any other.
const DesktopAccessContext tobyPredictionAccessContext = DesktopAccessContext(
  feature: DesktopFeature.tobyPrediction,
  action: DesktopAction.view,
  origin: DesktopDiscoveryOrigin.localFile,
);

/// Whether the client believes the reader has Premium. It gates nothing.
/// When Gamebase refuses a reading (403), it decides whether that earns one
/// fresh membership re-check (a purchase or renewal can lag on either side)
/// and which notice the refusal shows.
final tobyReaderHasPremiumProvider = Provider<bool>(
  (ref) =>
      desktopPremiumAccess(ref.watch(subscriptionProvider)) ==
      DesktopAccess.allowed,
);

/// The upgrade action of the view's notice when Gamebase answers a reading
/// with `premium_required` (its access setting is stricter than the
/// client's). Opens the window's Premium prompt for Toby Predicts;
/// [resume] runs once after a verified purchase, to ask again. Call only
/// from an explicit tap.
Future<bool> presentTobyServerGate(
  ProviderContainer container, {
  required String surface,
  DesktopAccessResume? resume,
}) => presentDesktopAccessDecision(
  container,
  const DesktopAccessDecision(
    DesktopAccess.premiumRequired,
    DesktopAccessReason.premiumTobyPrediction,
  ),
  // No context: the prompt targets Premium itself. A context would be
  // re-read against the client's rule, which lets everyone in.
  resume: resume,
  surface: surface,
);
