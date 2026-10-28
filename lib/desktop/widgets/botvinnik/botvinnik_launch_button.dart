import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/state/botvinnik_dock.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';

enum BotvinnikLaunchVariant {
  /// Matches [DesktopHeaderActionButton] peers in a pane header.
  header,

  /// Matches [DesktopToolbarPillButton] peers in a toolbar row.
  toolbar,
}

/// "Ask Botvinnik" launch for a screen. Opens the shell dock with
/// [screenContext]; hidden when Botvinnik is off in Settings or in the build.
class BotvinnikLaunchButton extends ConsumerWidget {
  const BotvinnikLaunchButton({
    super.key,
    required this.screenContext,
    this.variant = BotvinnikLaunchVariant.header,
    this.toolbarHeight = 34,
    this.tooltip = 'Ask Botvinnik about this page',
    this.leadingGap = 0,
  });

  final ChatScreenContext screenContext;
  final BotvinnikLaunchVariant variant;
  final double toolbarHeight;
  final String tooltip;

  /// Space before the button, rendered only when the button is, so hiding
  /// Botvinnik never leaves a stray gap in the row.
  final double leadingGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled =
        ChatApi.buildEnabled &&
        (ref.watch(botvinnikEnabledProvider).valueOrNull ?? true);
    if (!enabled) return const SizedBox.shrink();
    void launch() => openBotvinnikDock(ref, screenContext: screenContext);
    final button = switch (variant) {
      BotvinnikLaunchVariant.header => DesktopHeaderActionButton(
        label: 'Ask Botvinnik',
        icon: Icons.forum_outlined,
        tooltip: tooltip,
        onPress: launch,
      ),
      BotvinnikLaunchVariant.toolbar => DesktopToolbarPillButton(
        label: 'Ask Botvinnik',
        icon: Icons.forum_outlined,
        tooltip: tooltip,
        height: toolbarHeight,
        onPress: launch,
      ),
    };
    if (leadingGap <= 0) return button;
    return Padding(padding: EdgeInsets.only(left: leadingGap), child: button);
  }
}
