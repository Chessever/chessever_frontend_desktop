import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_guest_upgrade_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Canonical like/unlike for any game surface. Liking is free and never spends
/// a saved-game or database slot.
///
/// Waits for the liked list to load first: toggling against a list that has
/// not arrived yet would read "not liked" and insert a duplicate row.
///
/// Answers the like state the game was left in, or null when nothing changed
/// (sign-in declined, likes not loaded, or the write was rolled back).
Future<bool?> toggleDesktopGameLike({
  required BuildContext context,
  required WidgetRef ref,
  required GamesTourModel game,
}) async {
  // Phone guests can like games using their anonymous account. Mirror that
  // in the browser; preserve the native desktop sign-in flow.
  final user = ref.read(currentUserProvider);
  if (user == null || (!kIsWeb && user.isAnonymous)) {
    final signedIn = await showDesktopAccountSignIn(
      context,
      surface: 'like_game',
      title: 'Sign in to like games',
      message:
          'Liked games are saved to My Likes on every device and count '
          'toward the community Likes ranking.',
    );
    if (!signedIn || !context.mounted) return null;
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
    return null;
  }
  final notifier = ref.read(likedGamesProvider.notifier);
  final wasLiked = notifier.isLiked(likeId);
  final nowLiked = await notifier.toggle(game);
  if (!context.mounted) return nowLiked == wasLiked ? null : nowLiked;
  if (nowLiked == wasLiked) {
    showDesktopToast(
      context,
      wasLiked ? "Couldn't remove the like." : "Couldn't like this game.",
      error: true,
    );
    return null;
  }
  showDesktopToast(
    context,
    nowLiked ? 'Added to My Likes' : 'Removed from My Likes',
  );
  return nowLiked;
}
