import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/web_prep_access.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';

final webPrepSourcePaywallEnabledProvider = Provider<bool>((ref) => kIsWeb);

/// Prep downloads remain Prep content when reached through Library or a
/// restored board. Renamed sources retain registry provenance; older sources
/// can still be recognized in the app's generated workspace directory.
bool isWebPrepSourcePath(
  String path, {
  Iterable<LocalLibraryEntry> entries = const [],
}) {
  final normalized = p.normalize(path);
  final parts = p.split(normalized);
  final workspace = parts.lastIndexOf('player-workspace');
  if (workspace >= 0) return true;
  return entries.any(
    (entry) =>
        (playerWorkspaceIdFromLocalLibraryGroupId(entry.groupId) != null ||
            entry.playerWorkspaceSource != null) &&
        (p.equals(entry.path, normalized) ||
            p.isWithin(entry.path, normalized) ||
            p.isWithin(normalized, entry.path)),
  );
}

final webPrepSourceIdentityProvider = Provider.family<AsyncValue<bool>, String>(
  (ref, path) {
    if (!ref.watch(webPrepSourcePaywallEnabledProvider)) {
      return const AsyncValue.data(false);
    }
    if (isWebPrepSourcePath(path)) return const AsyncValue.data(true);
    final registry = ref.watch(localLibraryRegistryProvider);
    if (!registry.loaded) return const AsyncValue.loading();
    return AsyncValue.data(
      isWebPrepSourcePath(path, entries: registry.entries),
    );
  },
);

/// Null means an ordinary personal file. While provenance is loading, no
/// source reader mounts and no game is admitted as a free local document.
final webPrepSourceAccessDecisionProvider =
    Provider.family<DesktopAccessDecision?, String>((ref, path) {
      final prep = ref.watch(webPrepSourceIdentityProvider(path));
      if (!prep.hasValue) {
        return const DesktopAccessDecision(
          DesktopAccess.checking,
          DesktopAccessReason.entitlementChecking,
        );
      }
      if (prep.valueOrNull != true) return null;
      return ref.watch(desktopAccessDecisionProvider(webPrepContentAccess));
    });

/// Admission before a clicked Library preview starts scanning a Prep file.
Future<bool> requireWebPrepSourceAccess(
  ProviderContainer container,
  String path,
) async {
  if (!container.read(webPrepSourcePaywallEnabledProvider)) return true;
  if (!container.read(webPrepSourceIdentityProvider(path)).hasValue) {
    await container.read(localLibraryRegistryProvider.notifier).hydrated;
  }
  final decision = container.read(webPrepSourceAccessDecisionProvider(path));
  if (decision == null || decision.isAllowed) return true;
  return presentDesktopAccessDecision(
    container,
    decision,
    context: webPrepContentAccess,
    surface: 'prep_library',
  );
}
