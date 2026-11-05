import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/desktop/auth/web_prep_access.dart';
import 'package:chessever/desktop/auth/web_prep_source_access.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';

/// Board admission that belongs to a GAME's lifetime, not to an entitlement
/// poll.
///
/// * Native games retain their admitted lifetime. Web protected clean boards
///   recheck membership, so an old admission cannot outlive paid access.
/// * A tab with a draft or a committed save (restored session, detached
///   hand-off) is kept too: data is never hidden after downgrade.
/// * Anything else (restored state, detached boot, PiP restore, legacy
///   payloads) is decided here from the tab's provenance. Until it is
///   admitted the board content is NOT built, so no PGN hydrate, live stream
///   or engine starts. Rendering the locked surface never opens a paywall.
class DesktopBoardAccessGate extends ConsumerStatefulWidget {
  const DesktopBoardAccessGate({
    super.key,
    required this.tabId,
    required this.child,
  });

  final String tabId;
  final Widget child;

  @override
  ConsumerState<DesktopBoardAccessGate> createState() =>
      _DesktopBoardAccessGateState();
}

class _DesktopBoardAccessGateState
    extends ConsumerState<DesktopBoardAccessGate> {
  String? _admittedKey;

  void _latch(String key) {
    _admittedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(boardTabAdmissionByTabIdProvider.notifier);
      if (notifier.state[widget.tabId] == key) return;
      notifier.update((m) => <String, String>{...m, widget.tabId: key});
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabId = widget.tabId;
    final args = ref.watch(
      boardTabGameArgsByTabIdProvider.select((m) => m[tabId]),
    );
    if (args == null) return widget.child;
    final key = boardAdmissionKey(args);
    final latched = ref.watch(
      boardTabAdmissionByTabIdProvider.select((m) => m[tabId] == key),
    );
    final retainedWork = ref.watch(
      boardPaneSessionByTabIdProvider.select((m) {
        final session = m[tabId];
        return session != null &&
            (session.dirtySinceLoad || session.hasCommittedSave);
      }),
    );
    if (retainedWork) {
      _admittedKey = key;
      return widget.child;
    }

    final sourcePath = args.librarySaveOrigin?.sourcePath;
    if (sourcePath != null) {
      final prepDecision = ref.watch(
        webPrepSourceAccessDecisionProvider(sourcePath),
      );
      if (prepDecision != null && !prepDecision.isAllowed) {
        return DesktopAccessLockedSurface(
          decision: prepDecision,
          accessContext: webPrepContentAccess,
          surface: 'prep_game',
        );
      }
    }

    var accessContext = args.admissionContext;
    final classifyEvent =
        ref.watch(desktopPastEventAccessEnabledProvider) &&
        desktopGameNeedsEventClassification(accessContext, args.sourceGame);
    if (classifyEvent) {
      final resolved = ref.watch(
        desktopGameIsPastProvider(
          desktopGameEventKey(args.sourceGame!, accessContext),
        ),
      );
      final value = resolved.valueOrNull;
      if (value == null) {
        return DesktopAccessLockedSurface(
          decision: DesktopAccessDecision(
            resolved.hasError
                ? DesktopAccess.temporarilyUnavailable
                : DesktopAccess.checking,
            DesktopAccessReason.entitlementChecking,
          ),
          accessContext: desktopPastEventOpenContext,
          surface: 'event_game_access',
        );
      }
      accessContext = desktopGameEventAccessContext(accessContext, past: value);
    }
    final freeDecision = desktopAccessWithoutMembership(accessContext);
    final recheckProtectedWeb =
        ref.watch(desktopPastEventAccessEnabledProvider) &&
        !freeDecision.isAllowed;
    if (!recheckProtectedWeb &&
        (_admittedKey == key || (latched && !classifyEvent))) {
      _admittedKey = key;
      return widget.child;
    }
    // Free for everyone (an ordinary broadcast, a local file, an owned copy):
    // no membership read, no rebuild on entitlement polls.
    final decision =
        freeDecision.isAllowed
            ? freeDecision
            : ref.watch(desktopAccessDecisionProvider(accessContext));
    if (decision.isAllowed) {
      _latch(key);
      return widget.child;
    }
    return DesktopAccessLockedSurface(
      decision: decision,
      accessContext: accessContext,
      surface: 'board_locked',
    );
  }
}
