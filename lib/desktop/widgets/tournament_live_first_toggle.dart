import 'package:chessever/desktop/state/signed_out_events_presentation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_quick_list_toggles.dart';

class TournamentLiveFirstToggle extends ConsumerWidget {
  const TournamentLiveFirstToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readOnly = SignedOutEventsPresentationScope.maybeOf(context) != null;
    final enabled = !readOnly && ref.watch(tournamentLiveFirstProvider);

    return DesktopLiveFirstButton(
      pillKey: const ValueKey<String>('tournament-live-first-chrome'),
      pressed: enabled,
      subject: 'events',
      height: 38,
      onPress: () {
        if (!readOnly) ref.read(tournamentLiveFirstProvider.notifier).toggle();
      },
    );
  }
}
