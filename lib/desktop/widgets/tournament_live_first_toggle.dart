import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

class TournamentLiveFirstToggle extends ConsumerWidget {
  const TournamentLiveFirstToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(tournamentLiveFirstProvider);

    return DesktopTooltip(
      message:
          enabled
              ? 'Live events are shown first'
              : 'Keep the current event order',
      child: FTheme(
        data: FThemes.zinc.dark,
        child: Container(
          key: const ValueKey<String>('tournament-live-first-chrome'),
          height: 38,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color:
                enabled ? kPrimaryColor.withValues(alpha: 0.14) : kBlack2Color,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color:
                  enabled
                      ? kPrimaryColor.withValues(alpha: 0.65)
                      : kDividerColor,
            ),
          ),
          child: Semantics(
            button: true,
            toggled: enabled,
            label: 'Live first',
            child: FButton(
              style: desktopSegmentButtonStyle(selected: enabled),
              mainAxisSize: MainAxisSize.min,
              onPress:
                  () => ref.read(tournamentLiveFirstProvider.notifier).toggle(),
              prefix: Icon(
                Icons.bolt_rounded,
                color: enabled ? kPrimaryColor : kLightGreyColor,
              ),
              child: Text(
                'Live first',
                style: TextStyle(
                  color: enabled ? kPrimaryColor : kWhiteColor70,
                  fontSize: 12,
                  fontWeight: enabled ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
