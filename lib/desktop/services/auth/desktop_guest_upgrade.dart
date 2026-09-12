import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';
import 'package:chessever/desktop/services/auth/desktop_guest_account_merger.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/providers/guest_session_provider.dart';
import 'package:chessever/services/analytics/analytics_service.dart';

/// Identity providers a guest can upgrade with on desktop.
enum DesktopAccountProvider { google, apple }

/// One merger per engine, so capture and replay share a serial queue.
final desktopGuestAccountMergerProvider = Provider<DesktopGuestAccountMerger>(
  (ref) => DesktopGuestAccountMerger(
    gateway: SupabaseGuestAccountMergeGateway(Supabase.instance.client),
    pendingStore: FileGuestMergePendingStore(),
  ),
);

/// Thrown when the guest's data could not be read before signing in. The
/// sign-in is not started, so nothing is left behind.
class DesktopGuestDataCaptureException implements Exception {
  const DesktopGuestDataCaptureException(this.cause);

  final Object cause;

  @override
  String toString() => 'DesktopGuestDataCaptureException: $cause';
}

/// True when this window acts for an anonymous (guest) Supabase user.
bool desktopCurrentUserIsGuest() {
  if (!DesktopSupabaseInit.isInitialized) return false;
  try {
    return Supabase.instance.client.auth.currentUser?.isAnonymous == true;
  } catch (_) {
    return false;
  }
}

/// True when this window acts for a permanent (non-anonymous) account.
bool desktopCurrentUserIsPermanent() {
  if (!DesktopSupabaseInit.isInitialized) return false;
  try {
    final user = Supabase.instance.client.auth.currentUser;
    return user != null && user.isAnonymous != true;
  } catch (_) {
    return false;
  }
}

/// Signs the current window in with a permanent account.
///
/// Returns `true` only once a non-anonymous user is confirmed. The guest clock
/// is cleared at that point and never earlier, so a cancelled or failed
/// sign-in leaves the guest exactly where they were.
Future<bool> signInDesktopPermanentAccount(
  WidgetRef ref,
  DesktopAccountProvider provider, {
  required String surface,
}) async {
  final wasGuest = desktopCurrentUserIsGuest();
  final merger = ref.read(desktopGuestAccountMergerProvider);
  if (wasGuest) {
    final guestUserId = Supabase.instance.client.auth.currentUser?.id;
    if (guestUserId != null) {
      try {
        await merger.captureGuest(guestUserId);
      } catch (e) {
        throw DesktopGuestDataCaptureException(e);
      }
    }
  }
  final session = switch (provider) {
    DesktopAccountProvider.google =>
      await DesktopAuthService.instance.signInWithGoogle(),
    DesktopAccountProvider.apple =>
      await DesktopAuthService.instance.signInWithApple(),
  };
  final user = session?.user ?? Supabase.instance.client.auth.currentUser;
  if (user == null || user.isAnonymous == true) return false;

  await _replayPendingGuestMerge(merger, user, surface: surface);
  if (wasGuest) {
    await ref.read(guestSessionProvider.notifier).clearGuestSession();
  }
  AnalyticsService.instance.trackEventDetached(
    'Guest Upgrade Completed',
    properties: {
      'provider': provider.name,
      'surface': surface,
      'was_guest': wasGuest,
    },
  );
  return true;
}

/// Retries a guest merge left pending by an earlier failed attempt. Safe to
/// call on every permanent sign-in: with nothing pending it does nothing.
Future<void> retryPendingDesktopGuestMerge(WidgetRef ref) async {
  if (!DesktopSupabaseInit.isInitialized) return;
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null || user.isAnonymous == true) return;
  await _replayPendingGuestMerge(
    ref.read(desktopGuestAccountMergerProvider),
    user,
    surface: 'retry',
  );
}

Future<void> _replayPendingGuestMerge(
  DesktopGuestAccountMerger merger,
  User user, {
  required String surface,
}) async {
  final outcome = await merger.replayPending(
    targetUserId: user.id,
    targetIsExistingAccount: isLikelyExistingDesktopAccount(
      createdAt: user.createdAt,
      now: DateTime.now(),
    ),
  );
  if (outcome.status == GuestMergeStatus.nothingPending) return;
  if (outcome.error != null) {
    ErrorReporter.report(outcome.error!, tag: 'auth.guest_merge');
  }
  AnalyticsService.instance.trackEventDetached(
    'Guest Data Merge',
    properties: {
      'status': outcome.status.name,
      'writes': outcome.writeCount,
      'surface': surface,
    },
  );
}

/// Short, user-facing text for a failed desktop sign-in.
String desktopSignInErrorMessage(Object error) {
  final text = error.toString();
  if (kDebugMode) debugPrint('[GuestUpgrade] sign-in failed: $text');
  if (error is DesktopGuestDataCaptureException) {
    return 'Could not save your guest data before signing in. '
        'Check your connection and try again.';
  }
  if (text.contains('canceled') || text.contains('cancelled')) {
    return 'Sign-in was cancelled.';
  }
  if (text.contains('TimeoutException') || text.contains('timed out')) {
    return 'Sign-in timed out. Try again.';
  }
  if (text.contains('GOOGLE_DESKTOP_CLIENT_ID')) {
    return 'Google sign-in is not configured for this build.';
  }
  return 'Sign-in failed. Please try again.';
}
