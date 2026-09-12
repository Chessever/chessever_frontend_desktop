import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/auth/desktop_guest_gate.dart';
import 'package:chessever/desktop/auth/desktop_welcome_screen.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/widgets/mandatory_update_gate.dart';
import 'package:chessever/desktop/widgets/desktop_window_frame.dart';
import 'package:chessever/repository/authentication/auth_repository.dart';
import 'package:chessever/theme/app_theme.dart';

/// What the root of the main desktop window shows.
enum DesktopAuthGateView { loading, welcome, shell }

/// Progress of the automatic guest (anonymous) session for this launch.
enum DesktopGuestBootstrap { idle, inFlight, failed }

/// Root content widget for the main desktop window.
///
/// ChessEver Desktop is free to use. Guests and signed-in free users reach
/// the same shell as subscribers; premium decisions happen per feature, never
/// at the entrance, and entitlement refreshes, purchases, expiry or a network
/// failure never swap the shell out for a wall.
///
/// 1. **Restoring** the persisted session: a short loading frame.
/// 2. **Any session** (guest or permanent) → [DesktopShell].
/// 3. **No session on launch** → a guest session is created automatically,
///    reusing [AuthController.signInAnonymously].
/// 4. **Explicit sign-out, or guest creation failed** → [DesktopWelcomeScreen],
///    which offers sign-in and "Continue as guest".
class DesktopAuthGate extends HookConsumerWidget {
  const DesktopAuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!DesktopSupabaseInit.isInitialized) {
      // No backend available: surface the shell so panes can still be
      // developed locally.
      return const DesktopShell();
    }

    final auth = Supabase.instance.client.auth;
    final session = useState<Session?>(auth.currentSession);
    final restoring = useState<bool>(true);
    final bootstrap = useState<DesktopGuestBootstrap>(
      DesktopGuestBootstrap.idle,
    );
    final signedOutThisRun = useRef<bool>(false);
    final container = ProviderScope.containerOf(context, listen: false);

    Future<void> startGuestSession() async {
      if (bootstrap.value == DesktopGuestBootstrap.inFlight) return;
      // Never mint a second guest while any user (anonymous or not) exists.
      if (auth.currentUser != null) return;
      bootstrap.value = DesktopGuestBootstrap.inFlight;
      // authStateProvider auto-disposes; hold it for the length of the call.
      final keepAlive = container.listen(authStateProvider, (_, _) {});
      try {
        await container.read(authStateProvider.notifier).signInAnonymously();
        if (context.mounted) bootstrap.value = DesktopGuestBootstrap.idle;
      } catch (e, st) {
        ErrorReporter.report(e, stackTrace: st, tag: 'auth.guest_bootstrap');
        if (context.mounted) bootstrap.value = DesktopGuestBootstrap.failed;
      } finally {
        keepAlive.close();
      }
    }

    useEffect(() {
      var disposed = false;
      final sub = auth.onAuthStateChange.listen((event) {
        if (!restoring.value && event.event == AuthChangeEvent.signedOut) {
          signedOutThisRun.value = true;
        }
        session.value = event.session;
      });

      unawaited(
        Future<void>(() async {
          final restoredSession = await _restoreDesktopSession();
          if (disposed) return;
          session.value = restoredSession;
          restoring.value = false;
          if (shouldBootstrapDesktopGuest(
            hasSession: restoredSession != null,
            hasCurrentUser: auth.currentUser != null,
            signedOutThisRun: signedOutThisRun.value,
            bootstrap: bootstrap.value,
          )) {
            await startGuestSession();
          }
        }),
      );

      return () {
        disposed = true;
        unawaited(sub.cancel());
      };
    }, const []);

    switch (resolveDesktopAuthGateView(
      restoring: restoring.value,
      hasSession: session.value != null,
      bootstrap: bootstrap.value,
    )) {
      case DesktopAuthGateView.loading:
        return const DesktopStandaloneWindowChrome(child: _GateLoading());
      case DesktopAuthGateView.welcome:
        return DesktopStandaloneWindowChrome(
          child: DesktopWelcomeScreen(onContinueAsGuest: startGuestSession),
        );
      case DesktopAuthGateView.shell:
        return const MandatoryUpdateGate(
          child: DesktopGuestGateListener(child: DesktopShell()),
        );
    }
  }
}

/// Routing for the main window. Subscription state is deliberately absent:
/// the entrance never depends on entitlement.
@visibleForTesting
DesktopAuthGateView resolveDesktopAuthGateView({
  required bool restoring,
  required bool hasSession,
  required DesktopGuestBootstrap bootstrap,
}) {
  if (restoring) return DesktopAuthGateView.loading;
  if (hasSession) return DesktopAuthGateView.shell;
  if (bootstrap == DesktopGuestBootstrap.inFlight) {
    return DesktopAuthGateView.loading;
  }
  return DesktopAuthGateView.welcome;
}

/// A guest session is created automatically only on launch with no user at
/// all. After an explicit sign-out the user chose to leave, so the welcome
/// screen is shown and a guest is created only if they ask for it.
@visibleForTesting
bool shouldBootstrapDesktopGuest({
  required bool hasSession,
  required bool hasCurrentUser,
  required bool signedOutThisRun,
  required DesktopGuestBootstrap bootstrap,
}) {
  if (hasSession || hasCurrentUser) return false;
  if (signedOutThisRun) return false;
  return bootstrap == DesktopGuestBootstrap.idle;
}

Future<Session?> _restoreDesktopSession() async {
  final auth = Supabase.instance.client.auth;
  final session = auth.currentSession;
  if (session == null) return null;
  if (!session.isExpired) return session;

  try {
    final refreshed = await auth.refreshSession().timeout(
      const Duration(seconds: 6),
    );
    return refreshed.session ?? auth.currentSession;
  } catch (e) {
    if (isLikelyOfflineAuthRefreshFailure(e)) {
      // Keep the cached session mounted while offline. The shell is free, so
      // this no longer depends on a cached entitlement, and signing a guest
      // out here would orphan everything tied to their anonymous user id.
      return session;
    }
    try {
      await auth.signOut();
    } catch (_) {}
    return null;
  }
}

@visibleForTesting
bool isLikelyOfflineAuthRefreshFailure(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('timeout') ||
      text.contains('socketexception') ||
      text.contains('failed host lookup') ||
      text.contains('network') ||
      text.contains('connection') ||
      text.contains('connection closed') ||
      text.contains('connection refused') ||
      text.contains('clientexception') ||
      text.contains('xmlhttprequest error');
}

class _GateLoading extends StatelessWidget {
  const _GateLoading();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBackgroundColor,
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
        ),
      ),
    );
  }
}
