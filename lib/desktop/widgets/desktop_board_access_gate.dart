import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/desktop/auth/web_prep_access.dart';
import 'package:chessever/desktop/auth/web_prep_source_access.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_spinner.dart';
import 'package:chessever/theme/app_theme.dart';

/// Browser clean boards recheck membership; admitted native sessions retain
/// their lifetime. This is independent of archived-game classification.
final desktopBoardMembershipRecheckEnabledProvider = Provider<bool>(
  (_) => kIsWeb,
);

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
    final admitted = _admittedKey == key || latched;
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
        // Event freshness is not membership. A board the user is already
        // watching stays mounted while it settles, and a fresh one shows a
        // neutral progress line: claiming a membership check here put
        // "Checking your membership" over live games on every tick.
        if (admitted) return widget.child;
        return resolved.hasError
            ? _BoardOpeningSurface(
              onRetry:
                  () => ref.invalidate(
                    desktopGameIsPastProvider(
                      desktopGameEventKey(args.sourceGame!, accessContext),
                    ),
                  ),
            )
            : const _BoardOpeningSurface();
      }
      accessContext = desktopGameEventAccessContext(accessContext, past: value);
    }
    final freeDecision = desktopAccessWithoutMembership(accessContext);
    final recheckProtectedWeb =
        ref.watch(desktopBoardMembershipRecheckEnabledProvider) &&
        !freeDecision.isAllowed;
    if (!recheckProtectedWeb && admitted) {
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

/// Progress for a board that is still being admitted.
///
/// Deliberately says nothing about membership: event freshness is not an
/// entitlement check, and using the membership copy here made live boards
/// flash "Checking your membership" while a classification settled.
class _BoardOpeningSurface extends StatelessWidget {
  const _BoardOpeningSurface({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = onRetry != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!failed)
              const SizedBox(
                width: 18,
                height: 18,
                child: DesktopSpinner(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(kPrimaryColor),
                  backgroundColor: kDividerColor,
                ),
              ),
            if (failed) ...[
              const Text(
                'Could not open this game',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Check your connection and retry.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kWhiteColor70, fontSize: 13),
              ),
            ] else
              const Text(
                'Opening this game',
                textAlign: TextAlign.center,
                style: TextStyle(color: kWhiteColor70, fontSize: 13),
              ),
            if (failed) ...[
              const SizedBox(height: 16),
              DesktopDialogButton(
                label: 'Retry',
                tone: DesktopDialogButtonTone.primary,
                onPress: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
