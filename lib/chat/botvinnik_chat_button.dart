import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/botvinnik_icon.dart';
import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/chat/chat_screen.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

/// Global desktop entry point for Botvinnik.
///
/// The shell owns this button so it remains available while users move among
/// tabs. The active tab supplies optional entity context for each chat open.
class BotvinnikChatButton extends ConsumerWidget {
  const BotvinnikChatButton({this.screenContext, super.key});

  final ChatScreenContext? screenContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(botvinnikEnabledProvider).valueOrNull ?? true;
    if (!ChatApi.buildEnabled || !enabled) return const SizedBox.shrink();

    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: 'Ask Botvinnik',
        tipAnchor: Alignment.bottomRight,
        child: SizedBox.square(
          dimension: 58,
          child: FButton.icon(
            style: _floatingButtonStyle(),
            onPress:
                () => ChatScreen.show(
                  context,
                  screenContext: screenContext,
                  createNewConversationOnOpen: true,
                ),
            child: const BotvinnikIcon(
              size: 54,
              color: kPrimaryColor,
              showShadow: true,
            ),
          ),
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _floatingButtonStyle() {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(12),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.36),
          borderRadius: BorderRadius.circular(12),
        ),
        WidgetState.any: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(12),
        ),
      }),
      iconContentStyle:
          (content) => content.copyWith(padding: const EdgeInsets.all(2)),
    ),
  );
}
