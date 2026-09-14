import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/repository/freemium/freemium_quota_queue.dart';
import 'package:chessever/repository/freemium/freemium_quota_repository.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:chessever/utils/freemium_quota_guard.dart';
import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// UI admission and the entire write are serialized, not merely COUNT calls.
/// This does not replace the pending cross-device server transaction.
final _favoriteActions = FreemiumQuotaQueue();

/// A denial must be presented by the foreground handler; legacy standings
/// notifiers swallow write exceptions and optimistically publish a false add.
Future<bool> runDesktopFavoriteMutation({
  required bool adding,
  required Future<FreemiumQuotaResult> Function() check,
  required Future<void> Function() mutate,
  required Future<void> Function(FreemiumQuotaResult) showLimit,
  required VoidCallback showRetry,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent()) return false;
  try {
    if (adding) {
      final result = await check();
      if (!isCurrent()) return false;
      if (!result.isAllowed) {
        if (result.outcome == FreemiumQuotaOutcome.quotaExceeded) {
          await showLimit(result);
        } else {
          showRetry();
        }
        return false;
      }
    }
    if (!isCurrent()) return false;
    await mutate();
    return isCurrent();
  } on FavoriteLimitExceededException catch (error) {
    if (isCurrent()) {
      await showLimit(
        FreemiumQuotaResult(
          kind: FreemiumQuotaKind.favoritePlayers,
          outcome: FreemiumQuotaOutcome.quotaExceeded,
          reason: 'quota_exceeded',
          source: FreemiumQuotaSource.server,
          requested: 1,
          used: error.limit,
          limit: error.limit,
        ),
      );
    }
  } catch (_) {
    if (isCurrent()) showRetry();
  }
  return false;
}

/// Shared Desktop heart/context-menu path. Only player favorites are capped;
/// event favorite actions intentionally do not call this helper.
Future<void> setDesktopPlayerFavorite(
  BuildContext context,
  WidgetRef ref, {
  required bool favorite,
  required String playerName,
  String? fideId,
  String? countryCode,
  int? rating,
  String? title,
  String? gamebasePlayerId,
  String? memorialSourceIdentity,
  String? memorialRouteId,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final beforeAuth = container.read(desktopAccountIdentityProvider);
  if (!await requireFullAuthGuard(context) || !context.mounted) return;
  final account = container.read(desktopAccountIdentityProvider);
  if (account.staleSession ||
      (beforeAuth.isSignedIn && beforeAuth != account)) {
    return;
  }
  bool current() =>
      context.mounted &&
      container.read(desktopAccountIdentityProvider) == account &&
      !account.staleSession;
  await _favoriteActions.run(() async {
    if (!current()) return;
    await runDesktopFavoriteMutation(
      adding: favorite,
      check: () async {
        final result = await container
            .read(freemiumQuotaRepositoryProvider)
            .check(FreemiumQuotaKind.favoritePlayers);
        if (!current()) return result;
        if (result.source == FreemiumQuotaSource.clientFallback &&
            (result.isPremium ||
                result.outcome == FreemiumQuotaOutcome.quotaExceeded)) {
          final membership = desktopPremiumAccess(
            container.read(subscriptionProvider),
          );
          if (membership == DesktopAccess.checking ||
              membership == DesktopAccess.temporarilyUnavailable) {
            return FreemiumQuotaResult.unavailable(
              FreemiumQuotaKind.favoritePlayers,
              1,
              reason: 'membership_unverified',
              source: FreemiumQuotaSource.clientFallback,
            );
          }
        }
        return result;
      },
      isCurrent: current,
      mutate: () async {
        final notifier = container.read(favoritePlayersProviderNew.notifier);
        if (favorite) {
          await notifier.addFavorite(
            fideId: fideId,
            playerName: playerName,
            countryCode: countryCode,
            rating: rating,
            title: title,
            gamebasePlayerId: gamebasePlayerId,
            memorialSourceIdentity: memorialSourceIdentity,
            memorialRouteId: memorialRouteId,
          );
        } else {
          await container.read(favoritePlayersProviderNew.future);
          if (!current()) return;
          await notifier.removeFavorite(
            playerName,
            fideId: fideId,
            memorialSourceIdentity: memorialSourceIdentity,
          );
        }
      },
      showLimit: (result) async {
        if (!current()) return;
        await showDesktopPaywall(
          context,
          freemiumQuotaDesktopDecision(result),
          surface: 'favorite_player_limit',
        );
      },
      showRetry:
          () => showDesktopToast(
            context,
            'Could not update favorite. Please retry.',
            error: true,
          ),
    );
  });
}
