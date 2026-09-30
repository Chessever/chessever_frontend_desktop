import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Canonical like/unlike for any game surface. Liking is free and never spends
/// a saved-game or database slot.
///
/// Waits for the liked list to load first: toggling against a list that has
/// not arrived yet would read "not liked" and insert a duplicate row.
Future<void> toggleDesktopGameLike({
  required BuildContext context,
  required WidgetRef ref,
  required GamesTourModel game,
}) async {
  if (ref.read(currentUserProvider) == null) {
    showDesktopToast(context, 'Sign in to like games.');
    return;
  }
  final likeId = game.likeId;
  try {
    await ref.read(likedGamesProvider.future);
  } catch (_) {
    if (context.mounted) {
      showDesktopToast(
        context,
        "Couldn't load your likes. Try again.",
        error: true,
      );
    }
    return;
  }
  final notifier = ref.read(likedGamesProvider.notifier);
  final wasLiked = notifier.isLiked(likeId);
  final nowLiked = await notifier.toggle(game);
  if (!context.mounted) return;
  if (nowLiked == wasLiked) {
    showDesktopToast(
      context,
      wasLiked ? "Couldn't remove the like." : "Couldn't like this game.",
      error: true,
    );
    return;
  }
  showDesktopToast(
    context,
    nowLiked ? 'Added to My Likes' : 'Removed from My Likes',
  );
}
