import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/desktop/widgets/desktop_access_gate.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';

/// Fresh counts cover all databases, including bulk imports. These are client
/// admission checks: only an atomic server transaction can enforce concurrent
/// cross-device quota. Do not claim COUNT + INSERT is a reservation.
Future<bool> canAddDesktopCloudGames(
  BuildContext context, {
  int additions = 1,
}) async {
  if (additions < 0) return false;
  if (additions == 0) return true; // existing update, even above the cap
  final container = ProviderScope.containerOf(context, listen: false);
  final account = Supabase.instance.client.auth.currentUser?.id;
  if (account == null) return false;
  var access = container.read(desktopPremiumAccessProvider);
  if (access == DesktopAccess.allowed) return true;

  try {
    final count =
        await container
            .read(libraryRepositoryProvider)
            .getTotalAnalysisCountForCurrentUser();
    if (!context.mounted ||
        Supabase.instance.client.auth.currentUser?.id != account) {
      return false;
    }
    access = container.read(desktopPremiumAccessProvider);
    if (access == DesktopAccess.allowed) return true;
    if (desktopQuotaFits(count, additions, desktopFreeCloudGames)) {
      return true;
    }
    return requireDesktopPremium(context, feature: 'More than 10 cloud games');
  } catch (_) {
    if (context.mounted) {
      showDesktopToast(
        context,
        'Could not verify your saved-game count. Retry.',
        error: true,
      );
    }
    return false;
  }
}

Future<bool> canAddDesktopFavorite(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final client = Supabase.instance.client;
  final account = client.auth.currentUser?.id;
  if (account == null) return false;
  var access = container.read(desktopPremiumAccessProvider);
  if (access == DesktopAccess.allowed) return true;

  try {
    final count = await client
        .from('user_favorite_players')
        .count(CountOption.exact)
        .eq('user_id', account);
    if (!context.mounted || client.auth.currentUser?.id != account) {
      return false;
    }
    access = container.read(desktopPremiumAccessProvider);
    if (access == DesktopAccess.allowed) return true;
    if (desktopQuotaFits(count, 1, desktopFreeFavoritePlayers)) {
      return true;
    }
    return requireDesktopPremium(
      context,
      feature: 'More than 3 favorite players',
    );
  } catch (_) {
    if (context.mounted) {
      showDesktopToast(
        context,
        'Could not verify your favorite count. Retry.',
        error: true,
      );
    }
    return false;
  }
}
