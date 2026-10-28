import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/repository/local_storage/sesions_manager/session_manager.dart';
import 'package:chessever/services/analytics/analytics_service.dart';

/// Thrown when account deletion fails. [message] is safe to show the user;
/// it never carries backend error text.
class DesktopAccountDeletionException implements Exception {
  const DesktopAccountDeletionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Permanently deletes the signed-in account from desktop.
///
/// Follows the phone's `AuthController.deleteAccount` order:
///  1. best-effort identity-provider sign-out,
///  2. `public.delete_user_account()` (no arguments; FK cascade removes
///     favorites, engine settings, books and saved analyses),
///  3. analytics `delete_account`,
///  4. `SessionManager.clearAllUserData()`,
///  5. best-effort local Supabase sign-out.
///
/// When the RPC fails it still clears local data and signs out locally, so
/// the app never sits in a half-deleted session, then throws a
/// [DesktopAccountDeletionException] with user-facing copy.
///
/// Two deliberate differences from the phone:
///  - Desktop does not go through `authStateProvider`. Building that
///    controller would start the Google Sign-In SDK and the phone auth
///    listener, neither of which desktop runs. Desktop Google OAuth is a
///    one-shot loopback flow with no SDK session to revoke.
///  - Once the RPC has succeeded the account is gone, so a local cleanup
///    failure afterwards is reported but does not claim deletion failed.
class DesktopAccountDeletion {
  const DesktopAccountDeletion({
    required this.deleteRemoteAccount,
    required this.clearAllUserData,
    required this.signOutLocal,
    this.signOutIdentityProviders,
    this.trackResult,
    this.reportError,
  });

  final Future<void> Function() deleteRemoteAccount;
  final Future<void> Function() clearAllUserData;
  final Future<void> Function() signOutLocal;
  final Future<void> Function()? signOutIdentityProviders;
  final void Function({required bool success, String? reason})? trackResult;
  final void Function(Object error, StackTrace stackTrace)? reportError;

  Future<void> run() async {
    await _bestEffort(signOutIdentityProviders);

    try {
      await deleteRemoteAccount();
    } catch (error, stackTrace) {
      reportError?.call(error, stackTrace);
      trackResult?.call(success: false, reason: error.toString());
      // Still clear local state so a failed deletion cannot leave a stale
      // session behind.
      await _bestEffort(clearAllUserData);
      await _bestEffort(signOutLocal);
      throw DesktopAccountDeletionException(
        desktopAccountDeletionMessage(error),
      );
    }

    trackResult?.call(success: true);
    await _bestEffort(clearAllUserData);
    await _bestEffort(signOutLocal);
  }

  Future<void> _bestEffort(Future<void> Function()? step) async {
    if (step == null) return;
    try {
      await step();
    } catch (error, stackTrace) {
      reportError?.call(error, stackTrace);
    }
  }
}

/// Maps a deletion failure onto safe copy. Raw backend text never reaches
/// the UI. Every message tells the user to sign in again, because a failed
/// deletion has already signed them out on this computer.
String desktopAccountDeletionMessage(Object error) {
  final raw = error.toString().toLowerCase();
  if (raw.contains('socketexception') ||
      raw.contains('clientexception') ||
      raw.contains('failed host lookup') ||
      raw.contains('network is unreachable') ||
      raw.contains('connection refused')) {
    return 'No internet connection. Sign in again once you are online to '
        'retry.';
  }
  if (error is TimeoutException ||
      raw.contains('timeout') ||
      raw.contains('timed out')) {
    return 'The request timed out. Sign in again to retry.';
  }
  if (raw.contains('not authenticated') ||
      raw.contains('jwt expired') ||
      raw.contains('unauthorized')) {
    return 'Your session had expired. Sign in again to retry.';
  }
  return 'Could not delete your account. Sign in again to retry, or '
      'contact support if it keeps failing.';
}

final desktopAccountDeletionProvider = Provider<DesktopAccountDeletion>((ref) {
  return DesktopAccountDeletion(
    deleteRemoteAccount: () async {
      await Supabase.instance.client
          .rpc<dynamic>('delete_user_account')
          .timeout(const Duration(seconds: 30));
    },
    clearAllUserData: () => ref.read(sessionManagerProvider).clearAllUserData(),
    signOutLocal:
        () => Supabase.instance.client.auth.signOut(scope: SignOutScope.local),
    trackResult: ({required bool success, String? reason}) {
      unawaited(
        AnalyticsService.instance.trackAuthEvent(
          action: 'delete_account',
          success: success,
          reason: reason,
        ),
      );
    },
    reportError:
        (error, stackTrace) => ErrorReporter.report(
          error,
          stackTrace: stackTrace,
          tag: 'auth.delete_account',
        ),
  );
});
