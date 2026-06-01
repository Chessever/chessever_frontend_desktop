import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/widgets/player_score_card_view.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show
        scoreCardGamesContextProvider,
        scoreCardHasEventContextProvider,
        scoreCardPlayerProfileDataSourceProvider,
        selectedPlayerProvider;
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart'
    show selectedBroadcastModelProvider;
import 'package:chessever/theme/app_theme.dart';

/// Desktop pane that hosts a player's score card.
///
/// Resolves the per-tab `PlayerStandingModel` (stashed by
/// `playerScoreCardByTabIdProvider`) and renders [PlayerScoreCardView] —
/// the desktop-native two-column layout that replaces mobile's
/// `ScoreCardScreen`.
///
/// Mirrors the active player onto the legacy `selectedPlayerProvider` so
/// shared providers (player switcher, favorite toggle) keep reading off
/// the same global the mobile shell uses.
class PlayerScoreCardPane extends ConsumerWidget {
  const PlayerScoreCardPane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byTab = ref.watch(playerScoreCardByTabIdProvider);
    final player = byTab[tabId];
    final contextByTab = ref.watch(playerScoreCardContextByTabIdProvider);
    final tabContext = contextByTab[tabId];
    if (player == null) {
      return const _EmptyState(
        message: 'Tap a player name to open their score card.',
      );
    }

    // Sync the global the player switcher / favorite toggle still read off.
    final selected = ref.read(selectedPlayerProvider);
    if (selected?.name != player.name || selected?.fideId != player.fideId) {
      Future.microtask(() {
        if (!context.mounted) return;
        ref.read(selectedPlayerProvider.notifier).state = player;
      });
    }
    if (tabContext != null) {
      _syncLegacyScoreCardContext(context, ref, tabContext);
    }

    return PlayerScoreCardView(player: player, tabContext: tabContext);
  }

  void _syncLegacyScoreCardContext(
    BuildContext context,
    WidgetRef ref,
    PlayerScoreCardTabContext tabContext,
  ) {
    final gamesContextChanged =
        !identical(
          ref.read(scoreCardGamesContextProvider),
          tabContext.gamesContext,
        );
    final eventContextChanged =
        ref.read(scoreCardHasEventContextProvider) !=
        tabContext.hasEventContext;
    final profileSourceChanged =
        ref.read(scoreCardPlayerProfileDataSourceProvider) !=
        tabContext.profileDataSource;
    final selectedBroadcast = ref.read(selectedBroadcastModelProvider);
    final broadcastChanged =
        selectedBroadcast?.id != tabContext.selectedBroadcast?.id;

    if (!gamesContextChanged &&
        !eventContextChanged &&
        !profileSourceChanged &&
        !broadcastChanged) {
      return;
    }

    Future.microtask(() {
      if (!context.mounted) return;
      if (gamesContextChanged) {
        ref.read(scoreCardGamesContextProvider.notifier).state =
            tabContext.gamesContext;
      }
      if (eventContextChanged) {
        ref.read(scoreCardHasEventContextProvider.notifier).state =
            tabContext.hasEventContext;
      }
      if (profileSourceChanged) {
        ref.read(scoreCardPlayerProfileDataSourceProvider.notifier).state =
            tabContext.profileDataSource;
      }
      if (broadcastChanged) {
        ref.read(selectedBroadcastModelProvider.notifier).state =
            tabContext.selectedBroadcast;
      }
    });
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBackgroundColor,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.person_outline_rounded,
            color: kLightGreyColor,
            size: 28,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(color: kWhiteColor70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Convenience factory used by callers that have raw fields and need a
/// minimal `PlayerStandingModel` to push through `openPlayerScoreCard`
/// (board's player-name tap, position-games table, etc.).
PlayerStandingModel synthesizePlayerStandingModel({
  required String name,
  String? title,
  String? countryCode,
  int? rating,
  int? fideId,
}) {
  return PlayerStandingModel(
    countryCode: countryCode ?? '',
    title: (title != null && title.isNotEmpty) ? title : null,
    name: name,
    score: rating ?? 0,
    scoreChange: 0,
    matchScore: null,
    fideId: fideId,
  );
}
