import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';

class TournamentLiveFirstToggle extends ConsumerWidget {
  const TournamentLiveFirstToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(tournamentLiveFirstProvider);

    return DesktopToolbarPillButton(
      key: const ValueKey<String>('tournament-live-first-chrome'),
      label: 'Live first',
      icon: Icons.bolt_rounded,
      height: 38,
      tone:
          enabled
              ? DesktopToolbarPillTone.primary
              : DesktopToolbarPillTone.neutral,
      tooltip:
          enabled
              ? 'Live events are shown first'
              : 'Keep the current event order',
      onPress: () => ref.read(tournamentLiveFirstProvider.notifier).toggle(),
    );
  }
}
