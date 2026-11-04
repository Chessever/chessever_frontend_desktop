import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';

/// Browser policy follows the phone's PGN gates. Native file workflows keep
/// their existing access policy. Overridable so browser admission is tested
/// without a browser build.
final webPgnPaywallEnabledProvider = Provider<bool>((ref) => kIsWeb);

DesktopAccessContext webPgnAccessContext({required bool importing}) =>
    DesktopAccessContext(
      feature: importing ? DesktopFeature.pgnImport : DesktopFeature.pgnCopy,
      action: importing ? DesktopAction.acquireSource : DesktopAction.copy,
      origin: DesktopDiscoveryOrigin.localFile,
      quota: DesktopQuota.none,
    );

/// One PGN gate for clipboard, file, drop, menu and shortcut entry points.
/// Declining a paywall never reads, imports or copies any games. Copy FEN and
/// export/recovery of existing work do not use this gate.
Future<bool> ensureWebPgnAccess(
  BuildContext context, {
  required bool importing,
}) async {
  if (!context.mounted) return false;
  final container =
      context
          .getInheritedWidgetOfExactType<UncontrolledProviderScope>()
          ?.container;
  // Standalone native notation widgets predate the app's provider scope.
  // Browser operations still require a scope to verify their access policy.
  if (container == null) return !kIsWeb;
  if (!container.read(webPgnPaywallEnabledProvider)) return true;
  final allowed = await showDesktopPremiumPaywall(
    context,
    accessContext: webPgnAccessContext(importing: importing),
    surface: importing ? 'pgn_import' : 'copy_pgn',
  );
  return allowed && context.mounted;
}

/// Equivalent for service entry points with no widget context. The shell's
/// registered presenter owns the dialog and verifies membership afterward.
Future<bool> requireWebPgnImport(ProviderContainer container) {
  if (!container.read(webPgnPaywallEnabledProvider)) {
    return Future<bool>.value(true);
  }
  return requireDesktopAction(
    container,
    webPgnAccessContext(importing: true),
    surface: 'pgn_import',
  );
}
