import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/auth/desktop_premium_required_screen.dart';
import 'package:chessever/desktop/auth/desktop_welcome_screen.dart';
import 'package:chessever/desktop/services/desktop_offline_access_cache.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/widgets/mandatory_update_gate.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';

/// Root content widget for the desktop build. ChessEver Desktop is
/// **premium-only**. There is no local onboarding flow — country and
/// favorite players are configured server-side and synced on sign-in.
///
/// 1. **Signed out** → [DesktopWelcomeScreen]. Sign in.
/// 2. **Signed in but not premium** → [DesktopPremiumRequiredScreen].
/// 3. **Signed in and premium** → [DesktopShell]. Normal app.
class DesktopAuthGate extends HookConsumerWidget {
  const DesktopAuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!DesktopSupabaseInit.isInitialized) {
      // No backend available — surface the shell so we can still develop
      // panes locally. Premium gating will refuse anyway once backend is
      // wired up, so this only matters in development.
      return const DesktopShell();
    }

    final auth = Supabase.instance.client.auth;
    final session = useState<Session?>(auth.currentSession);
    final loading = useState<bool>(true);

    useEffect(() {
      var disposed = false;
      final sub = auth.onAuthStateChange.listen((event) {
        session.value = event.session;
      });

      unawaited(
        Future<void>(() async {
          final restoredSession = await _restoreDesktopSession();
          if (disposed) return;
          session.value = restoredSession;
          if (!disposed) loading.value = false;
        }),
      );

      return () {
        disposed = true;
        unawaited(sub.cancel());
      };
    }, const []);

    if (loading.value) return const _GateLoading();

    final s = session.value;

    if (s == null) {
      return const DesktopWelcomeScreen();
    }

    final subscription = ref.watch(subscriptionProvider);
    if (shouldShowDesktopSubscriptionGateLoading(subscription)) {
      return const _GateLoading();
    }
    if (!subscription.isSubscribed) {
      return const DesktopPremiumRequiredScreen();
    }

    return const MandatoryUpdateGate(child: DesktopShell());
  }
}

@visibleForTesting
bool shouldShowDesktopSubscriptionGateLoading(SubscriptionState subscription) {
  // Desktop entitlement refreshes run periodically while the shell is open.
  // If we replace the shell with the loading screen during those refreshes,
  // board panes are unmounted and their local cursor/analysis state snaps
  // back to the last persisted game position when the shell mounts again.
  return subscription.isLoading && !subscription.isSubscribed;
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
    if (isLikelyOfflineAuthRefreshFailure(e) &&
        await DesktopOfflineAccessCache.canUseOfflineAccess()) {
      // Keep the cached session mounted while offline so already-open boards,
      // local files, and cached games remain usable. Online entitlement/auth
      // refreshes will run again when connectivity returns.
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
