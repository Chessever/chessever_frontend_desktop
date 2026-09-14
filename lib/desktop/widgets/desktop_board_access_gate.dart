import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';

/// Board admission that belongs to a GAME's lifetime, not to an entitlement
/// poll.
///
/// * A game admitted in this tab (by the central open, or by this gate the
///   first time it saw an allowed decision) stays mounted for as long as the
///   tab holds that game. A routine refresh, an expiry or a downgrade never
///   unmounts it, so an unsaved draft survives.
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
    if (_admittedKey == key) return widget.child;

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
    if (latched || retainedWork) {
      _admittedKey = key;
      return widget.child;
    }

    final accessContext = args.admissionContext;
    // Free for everyone (an ordinary broadcast, a local file, an owned copy):
    // no membership read, no rebuild on entitlement polls.
    final freeDecision = desktopAccessWithoutMembership(accessContext);
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
