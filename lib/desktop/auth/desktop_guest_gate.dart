import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_guest_upgrade_dialog.dart';
import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';
import 'package:chessever/providers/guest_session_provider.dart';
import 'package:chessever/services/analytics/analytics_service.dart';

/// How long after the shell mounts before a reminder may interrupt. Session
/// restore, tab restore and the first pane load all land inside this window,
/// and a prompt racing them reads as a startup glitch.
const kDesktopGuestGateStartupSettle = Duration(seconds: 2);

/// Counts dialogs stacked on the main window's root navigator.
///
/// Desktop dialogs (`showDesktopModal`, `showDesktopDialog`) are popup routes
/// above the shell, so a non-page [ModalRoute] means something is already
/// asking for the user's attention.
class DesktopGuestGateObserver extends NavigatorObserver {
  DesktopGuestGateObserver._();

  static final DesktopGuestGateObserver instance = DesktopGuestGateObserver._();

  final ValueNotifier<int> modalDepth = ValueNotifier<int>(0);

  bool get isModalOpen => modalDepth.value > 0;

  bool _isModal(Route<dynamic>? route) =>
      route is ModalRoute && route is! PageRoute;

  void _bump(int delta) {
    final next = modalDepth.value + delta;
    modalDepth.value = next < 0 ? 0 : next;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isModal(route)) _bump(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isModal(route)) _bump(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isModal(route)) _bump(-1);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (_isModal(oldRoute)) _bump(-1);
    if (_isModal(newRoute)) _bump(1);
  }
}

/// What the guest reminder should do on this app entry.
enum DesktopGuestGateAction {
  none,
  startClock,
  initialPrompt,
  softPrompt,
  forcedSignIn,
}

/// Whether this is a safe moment to interrupt at all. Pure so the window,
/// dialog and startup rules are unit tested without a widget tree.
@visibleForTesting
bool canInterruptForDesktopGuestGate({
  required DesktopWindowRole windowRole,
  required bool startupComplete,
  required bool modalOpen,
  required bool entryCheckArmed,
  required bool handlingGate,
}) {
  if (windowRole != DesktopWindowRole.main) return false;
  if (!startupComplete || modalOpen) return false;
  return entryCheckArmed && !handlingGate;
}

/// The decision for a safe moment. [session] `null` means the stamps are still
/// being read from SharedPreferences.
@visibleForTesting
DesktopGuestGateAction resolveDesktopGuestGateAction({
  required bool isGuest,
  required GuestSessionState? session,
  required DateTime now,
  bool promptOnFirstEntry = false,
}) {
  if (!isGuest || session == null) return DesktopGuestGateAction.none;
  // Legacy anonymous installs (from before guest mode) have no stamp: start
  // their clock now instead of locking them out immediately.
  if (!session.hasGuestClock) {
    return promptOnFirstEntry
        ? DesktopGuestGateAction.initialPrompt
        : DesktopGuestGateAction.startClock;
  }
  return switch (session.gateAt(now)) {
    GuestGate.none => DesktopGuestGateAction.none,
    GuestGate.softPrompt => DesktopGuestGateAction.softPrompt,
    GuestGate.forcedSignUp => DesktopGuestGateAction.forcedSignIn,
  };
}

/// Owns the guest reminder schedule for the main desktop window:
///
/// * first browser entry: sign-in with a "Not now" guest path, like mobile.
/// * day 0-6 after that: silence; a guest has the full free app.
/// * day 7+: a dismissible reminder, re-asked at most weekly.
/// * day 28+: sign-in is required. The shell stays mounted underneath, so
///   open boards and drafts survive, and unsaved analysis can be exported
///   before signing in.
///
/// One check per app entry (launch or resume), never mid-navigation, never
/// over another dialog, never during startup, and never in a detached board
/// window.
class DesktopGuestGateListener extends ConsumerStatefulWidget {
  const DesktopGuestGateListener({
    required this.child,
    this.promptOnFirstEntry = false,
    super.key,
  });

  final Widget child;

  /// Mirrors the phone's final onboarding step in the browser. The persisted
  /// guest clock makes this a once-only prompt, including across page reloads.
  final bool promptOnFirstEntry;

  @override
  ConsumerState<DesktopGuestGateListener> createState() =>
      _DesktopGuestGateListenerState();
}

class _DesktopGuestGateListenerState
    extends ConsumerState<DesktopGuestGateListener>
    with WidgetsBindingObserver {
  bool _handlingGate = false;
  bool _entryCheckArmed = true;
  bool _startupComplete = false;
  Timer? _startupTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DesktopGuestGateObserver.instance.modalDepth.addListener(_scheduleEvaluate);
    ref.listenManual<DesktopAccountIdentity>(
      desktopAccountIdentityProvider,
      _onAccountChanged,
      fireImmediately: true,
    );
    _startupTimer = Timer(kDesktopGuestGateStartupSettle, () {
      if (!mounted) return;
      _startupComplete = true;
      _scheduleEvaluate();
    });
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    DesktopGuestGateObserver.instance.modalDepth.removeListener(
      _scheduleEvaluate,
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // A guest can cross the 7- or 28-day line while the app sits in the
    // background, so each return to the app is a new entry.
    _entryCheckArmed = true;
    unawaited(ref.read(guestSessionProvider.notifier).refresh());
    _scheduleEvaluate();
  }

  void _scheduleEvaluate() {
    if (!mounted) return;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) => unawaited(_evaluate()));
    // Startup timers, browser resumes and dialog closures can arrive while
    // the shell is idle. A post-frame callback alone never requests a frame.
    binding.ensureVisualUpdate();
  }

  Future<void> _evaluate() async {
    if (!mounted) return;
    if (!canInterruptForDesktopGuestGate(
      windowRole: ref.read(desktopWindowRoleProvider),
      startupComplete: _startupComplete,
      modalOpen: DesktopGuestGateObserver.instance.isModalOpen,
      entryCheckArmed: _entryCheckArmed,
      handlingGate: _handlingGate,
    )) {
      return;
    }

    final isGuest = ref.read(desktopAccountIdentityProvider).isGuest;
    if (!isGuest) {
      _entryCheckArmed = false;
      return;
    }
    final session = ref.read(guestSessionProvider).valueOrNull;
    if (session == null) return; // still reading prefs; retry on change

    final now = DateTime.now();
    final action = resolveDesktopGuestGateAction(
      isGuest: isGuest,
      session: session,
      now: now,
      promptOnFirstEntry: widget.promptOnFirstEntry,
    );
    // This entry has had its look; anything further waits for the next one.
    _entryCheckArmed = false;
    if (action == DesktopGuestGateAction.none) return;

    _handlingGate = true;
    try {
      switch (action) {
        case DesktopGuestGateAction.startClock:
          await ref.read(guestSessionProvider.notifier).startGuestSession();
        case DesktopGuestGateAction.initialPrompt:
          await ref.read(guestSessionProvider.notifier).startGuestSession();
          if (mounted) await _showSoftPrompt(session, now, initial: true);
        case DesktopGuestGateAction.softPrompt:
          await _showSoftPrompt(session, now);
        case DesktopGuestGateAction.forcedSignIn:
          await _showRequiredSignIn(session, now);
        case DesktopGuestGateAction.none:
          break;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[GuestSession] Gate handling failed: $e');
    } finally {
      _handlingGate = false;
    }
  }

  Future<void> _showSoftPrompt(
    GuestSessionState session,
    DateTime now, {
    bool initial = false,
  }) async {
    // Mark before showing: if the app dies while the prompt is up, skipping a
    // reminder beats greeting the guest with it on every cold start.
    await ref.read(guestSessionProvider.notifier).markPromptShown(now: now);
    final days = session.ageAt(now)?.inDays ?? 0;
    AnalyticsService.instance.trackEventDetached(
      'Guest Upgrade Prompt Shown',
      properties: {'guest_days': days, 'forced': false, 'initial': initial},
    );
    if (!mounted) return;
    await showDesktopGuestReminder(context, guestDays: days, initial: initial);
  }

  Future<void> _showRequiredSignIn(
    GuestSessionState session,
    DateTime now,
  ) async {
    final days = session.ageAt(now)?.inDays ?? 0;
    AnalyticsService.instance.trackEventDetached(
      'Guest Upgrade Forced',
      properties: {'guest_days': days},
    );
    if (!mounted) return;
    await showDesktopGuestRequiredSignIn(context, guestDays: days);
  }

  void _onAccountChanged(
    DesktopAccountIdentity? previous,
    DesktopAccountIdentity next,
  ) {
    if (next.isPermanent) {
      // Also handle the already-restored account after a browser OAuth
      // redirect, when there need not be another account-change event.
      unawaited(_finishGuestSession(next));
      return;
    }
    if (previous?.userId != next.userId ||
        previous?.isAnonymous != next.isAnonymous) {
      _entryCheckArmed = true;
      _scheduleEvaluate();
    }
  }

  Future<void> _finishGuestSession(DesktopAccountIdentity account) async {
    try {
      await ref.read(guestSessionProvider.future);
      if (!mounted || ref.read(desktopAccountIdentityProvider) != account) {
        return;
      }
      await ref.read(guestSessionProvider.notifier).clearGuestSession();
      if (mounted && ref.read(desktopAccountIdentityProvider) == account) {
        await retryPendingDesktopGuestMerge(ref);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[GuestSession] Account cleanup failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<GuestSessionState>>(
      guestSessionProvider,
      (_, _) => _scheduleEvaluate(),
    );
    return widget.child;
  }
}
