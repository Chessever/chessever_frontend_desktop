import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_guest_gate.dart';
import 'package:chessever/desktop/auth/desktop_guest_upgrade_dialog.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';

/// Browser startup enables immediate sign-in on interaction. Native apps keep
/// the phone's free guest access and its existing per-action account checks.
final desktopGuestInteractionSignInProvider = Provider<bool>((ref) => false);

/// Keeps the shell visible, but consumes guest interactions before a control
/// can navigate or mutate data. Dialogs live on the root navigator above this
/// widget, so their buttons, focus traversal and dismissal remain available.
class DesktopGuestInteractionGate extends ConsumerStatefulWidget {
  const DesktopGuestInteractionGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DesktopGuestInteractionGate> createState() =>
      _DesktopGuestInteractionGateState();
}

class _DesktopGuestInteractionGateState
    extends ConsumerState<DesktopGuestInteractionGate> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Guest sign-in gate');
  bool _promptOpen = false;
  bool? _blocked;
  bool _needsShellFocus = false;

  @override
  void initState() {
    super.initState();
    DesktopGuestGateObserver.instance.modalDepth.addListener(_restoreFocus);
  }

  @override
  void dispose() {
    DesktopGuestGateObserver.instance.modalDepth.removeListener(_restoreFocus);
    _focusNode.dispose();
    super.dispose();
  }

  void _restoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || DesktopGuestGateObserver.instance.isModalOpen) return;
      if (_blocked == true) {
        _focusNode.requestFocus();
      } else if (_needsShellFocus) {
        // The shell's initial autofocus ran while its descendants were
        // excluded. Enter its traversal order when account access is granted.
        _focusNode.nextFocus();
        _needsShellFocus = false;
      }
    });
  }

  Future<void> _requestSignIn() async {
    if (_promptOpen || DesktopGuestGateObserver.instance.isModalOpen) return;
    _promptOpen = true;
    try {
      await showDesktopAccountSignIn(
        context,
        surface: 'web_interaction',
        title: 'Sign in to keep going',
        message:
            'Sign in or create a free account to use ChessEver. '
            'Your chess stays with you on every device.',
      );
    } catch (error, stack) {
      ErrorReporter.report(error, stackTrace: stack, tag: 'auth.interaction');
    } finally {
      _promptOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(desktopGuestInteractionSignInProvider);
    final blocked =
        enabled && !ref.watch(desktopAccountIdentityProvider).isPermanent;
    if (_blocked != blocked) {
      _needsShellFocus = _blocked == true && !blocked;
      if (blocked || _blocked != null) _restoreFocus();
      _blocked = blocked;
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: blocked,
      canRequestFocus: blocked,
      skipTraversal: !blocked,
      descendantsAreFocusable: !blocked,
      onKeyEvent: (_, event) {
        if (!blocked) return KeyEventResult.ignored;
        // A modifier alone is not an action. The following key opens sign-in
        // before any shell shortcut or text field receives it.
        if (event is KeyDownEvent &&
            event.logicalKey != LogicalKeyboardKey.escape &&
            !<LogicalKeyboardKey>{
              LogicalKeyboardKey.controlLeft,
              LogicalKeyboardKey.controlRight,
              LogicalKeyboardKey.metaLeft,
              LogicalKeyboardKey.metaRight,
              LogicalKeyboardKey.altLeft,
              LogicalKeyboardKey.altRight,
              LogicalKeyboardKey.shiftLeft,
              LogicalKeyboardKey.shiftRight,
            }.contains(event.logicalKey)) {
          unawaited(_requestSignIn());
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        label: blocked ? 'Sign in to use ChessEver' : null,
        button: blocked,
        onTap: blocked ? () => unawaited(_requestSignIn()) : null,
        child: ExcludeSemantics(
          excluding: blocked,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: blocked ? (_) => unawaited(_requestSignIn()) : null,
            child: AbsorbPointer(absorbing: blocked, child: widget.child),
          ),
        ),
      ),
    );
  }
}
