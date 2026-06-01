import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/shell/desktop_pane.dart';

/// Public intent used by panes to ask the shell to switch the visible pane.
///
/// Dispatch with `Actions.maybeInvoke(context, SwitchPaneIntent(pane))`.
/// `DesktopShell` registers a handler that updates its local pane state.
class SwitchPaneIntent extends Intent {
  const SwitchPaneIntent(this.pane);
  final DesktopPane pane;
}

class DesktopShellIntents {
  DesktopShellIntents._();

  /// Convenience wrapper. Returns true if the action was dispatched.
  static bool switchPane(BuildContext context, DesktopPane pane) {
    final result = Actions.maybeInvoke(context, SwitchPaneIntent(pane));
    return result != null;
  }
}
