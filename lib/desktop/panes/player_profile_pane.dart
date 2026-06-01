import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/widgets/player_profile_view.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop pane that hosts a player's full profile.
///
/// Resolves the per-tab `PlayerProfileArgs` and renders the desktop-native
/// [PlayerProfileView] (left identity column + right tabs). Replaces the
/// previous shim that embedded the mobile `PlayerProfileScreen` verbatim.
class PlayerProfilePane extends ConsumerWidget {
  const PlayerProfilePane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = ref.watch(playerProfileByTabIdProvider)[tabId];
    if (args == null) return const _EmptyState();

    // Re-key the view on player identity so the IndexedStack tab bodies
    // (and their preserved scroll positions) reset cleanly on tab swap.
    return PlayerProfileView(
      key: ValueKey<String>(
        '${args.playerName}|${args.fideId ?? ''}|${args.dataSource.name}',
      ),
      args: args,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBackgroundColor,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: const Text(
        'No player profile open.',
        style: TextStyle(color: kWhiteColor70, fontSize: 13),
      ),
    );
  }
}
