import 'dart:async';
import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/chat/ai_sharing_consent.dart';
import 'package:chessever/repository/local_storage/local_storage_repository.dart';
import 'package:chessever/providers/guest_session_provider.dart';

/// Thrown when account deletion fails. [message] is safe to show the user;
/// it never carries backend error text.
class DesktopAccountDeletionException implements Exception {
  const DesktopAccountDeletionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DesktopAccountDeletionResult {
  const DesktopAccountDeletionResult({
    this.appleManualRevokeRequired = false,
    this.appleRevocationPending = false,
    this.dataRemovalPending = false,
  });

  factory DesktopAccountDeletionResult.fromResponse(Object? data) {
    if (data is! Map ||
        data['deleted'] != true ||
        data['apple_manual_revoke_required'] is! bool ||
        data['apple_revocation_pending'] is! bool ||
        data['data_removal_pending'] is! bool) {
      throw const DesktopAccountDeletionException(
        'Account deletion was not confirmed. Please try again.',
      );
    }
    return DesktopAccountDeletionResult(
      appleManualRevokeRequired: data['apple_manual_revoke_required'] == true,
      appleRevocationPending: data['apple_revocation_pending'] == true,
      dataRemovalPending: data['data_removal_pending'] == true,
    );
  }

  final bool appleManualRevokeRequired;
  final bool appleRevocationPending;
  final bool dataRemovalPending;
}

/// Removes only this account's stored identity, never another account's keys.
Future<void> clearDesktopDeletedAccountPreferences({
  required SharedPreferences prefs,
  required String accountId,
  required bool Function() isCurrentAccount,
  bool isGuest = false,
}) async {
  final keys = <String>{AiSharingConsent.keyFor(accountId)};
  for (final key in ['supabase_session', 'supabase_user']) {
    final value = prefs.getString(key);
    if (value == null) continue;
    try {
      final data = jsonDecode(value);
      if (data is Map &&
          (data['id'] == accountId ||
              (data['user'] is Map && data['user']['id'] == accountId))) {
        keys.add(key);
      }
    } on FormatException {
      // An unrecognized value is not proof it belongs to this account.
    }
  }
  if (isGuest && isCurrentAccount()) {
    keys.addAll([
      'guest_session_started_at_ms',
      'guest_session_last_prompt_at_ms',
    ]);
  }
  // Queue removals together before yielding. SharedPreferences updates its
  // cache synchronously; a later sign-in queues its new values after these.
  final removed = await Future.wait([
    for (final key in keys) prefs.remove(key),
  ]);
  if (removed.any((success) => !success)) {
    throw StateError('Local account data could not be cleared.');
  }
}

/// Permanently deletes the signed-in account from desktop.
///
/// Uses an authenticated server operation, followed by account-scoped cleanup:
///  1. best-effort identity-provider sign-out,
///  2. `delete-account` (queues Apple/external cleanup before deleting identity),
///  3. optional result callback,
///  4. remove only preferences belonging to the deleted account,
///  5. best-effort local Supabase sign-out.
///
/// Failed deletion retains the session so every account can retry.
/// A changed account is never cleared by another account's pending deletion.
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
    required this.clearAccountData,
    required this.signOutLocal,
    this.signOutIdentityProviders,
    this.trackResult,
    this.reportError,
    this.isCurrentAccount,
  });

  final Future<DesktopAccountDeletionResult> Function() deleteRemoteAccount;

  /// Must target the captured deleted account, even if another account signs in.
  final Future<void> Function() clearAccountData;
  final Future<void> Function() signOutLocal;
  final Future<void> Function()? signOutIdentityProviders;
  final void Function({required bool success, String? reason})? trackResult;
  final void Function(Object error, StackTrace stackTrace)? reportError;
  final bool Function()? isCurrentAccount;

  bool get _accountMatches => isCurrentAccount?.call() ?? true;

  Future<DesktopAccountDeletionResult> run() async {
    if (!_accountMatches) {
      throw const DesktopAccountDeletionException(
        'Your account changed. Please try again.',
      );
    }
    await _bestEffort(signOutIdentityProviders);

    late final DesktopAccountDeletionResult result;
    try {
      if (!_accountMatches) {
        throw const DesktopAccountDeletionException(
          'Your account changed. Please try again.',
        );
      }
      result = await deleteRemoteAccount();
    } catch (error, stackTrace) {
      reportError?.call(error, stackTrace);
      trackResult?.call(success: false, reason: error.toString());
      if (!_accountMatches) {
        throw const DesktopAccountDeletionException(
          'Your account changed. Please try again.',
        );
      }
      throw DesktopAccountDeletionException(
        desktopAccountDeletionMessage(error),
      );
    }

    trackResult?.call(success: true);
    await _bestEffort(clearAccountData);
    if (_accountMatches) await _bestEffort(signOutLocal);
    return result;
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
/// the UI. Failed requests retain the session for a direct retry.
String desktopAccountDeletionMessage(Object error) {
  final raw = error.toString().toLowerCase();
  if (raw.contains('socketexception') ||
      raw.contains('clientexception') ||
      raw.contains('failed host lookup') ||
      raw.contains('network is unreachable') ||
      raw.contains('connection refused')) {
    return 'No internet connection. Please try again once you are online.';
  }
  if (error is TimeoutException ||
      raw.contains('timeout') ||
      raw.contains('timed out')) {
    return 'The request timed out. Please try again.';
  }
  if (raw.contains('not authenticated') ||
      raw.contains('jwt expired') ||
      raw.contains('unauthorized')) {
    return 'Your session had expired. Sign in again to retry.';
  }
  return 'Could not delete your account. Please try again, or contact support '
      'if it keeps failing.';
}

final desktopAccountDeletionProvider = Provider.autoDispose<
  DesktopAccountDeletion
>((ref) {
  final isGuest =
      Supabase.instance.client.auth.currentUser?.isAnonymous == true;
  final accountId = Supabase.instance.client.auth.currentUser?.id;
  final guestSession = ref.read(guestSessionProvider.notifier);
  bool accountMatches() =>
      accountId != null &&
      Supabase.instance.client.auth.currentUser?.id == accountId;
  return DesktopAccountDeletion(
    isCurrentAccount: accountMatches,
    deleteRemoteAccount: () async {
      final auth = Supabase.instance.client.auth;
      var session = auth.currentSession;
      if (accountMatches() && session?.isExpired == true) {
        session = (await auth.refreshSession()).session;
      }
      final token = session?.accessToken;
      if (!accountMatches() || token == null) {
        throw const DesktopAccountDeletionException(
          'Your account changed. Please try again.',
        );
      }
      final response = await Supabase.instance.client.functions
          .invoke(
            'delete-account',
            headers: {'Authorization': 'Bearer $token'},
            body: const <String, dynamic>{},
          )
          .timeout(const Duration(seconds: 45));
      if (response.status != 200) {
        throw const DesktopAccountDeletionException(
          'Account deletion was not confirmed. Please try again.',
        );
      }
      return DesktopAccountDeletionResult.fromResponse(response.data);
    },
    clearAccountData: () async {
      final prefs = await SharedPreferencesService.instance.ensureInitialized();
      if (prefs == null || accountId == null) return;
      await clearDesktopDeletedAccountPreferences(
        prefs: prefs,
        accountId: accountId,
        isCurrentAccount: accountMatches,
        isGuest: isGuest,
      );
      if (isGuest && accountMatches()) await guestSession.refresh();
    },
    signOutLocal: () async {
      if (accountMatches()) {
        await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
      }
    },
    // An unsuccessful response can still follow a committed remote deletion.
    // Never identify the account again through deletion analytics.
    reportError:
        (error, stackTrace) => ErrorReporter.report(
          error,
          stackTrace: stackTrace,
          tag: 'auth.delete_account',
        ),
  );
});
