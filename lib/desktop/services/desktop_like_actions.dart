import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_guest_upgrade_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_like_tag_offer.dart';
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
  String? legacyLikeId,
}) async {
  // Likes live on the account (My Likes on every device, and the community
  // ranking), so a guest or signed-out window signs in first, then the like
  // goes through in the same click. Desktop and the web port share this gate.
  final user = ref.read(currentUserProvider);
  final listAtPress =
      user == null || user.isAnonymous ? null : ref.read(likedGamesProvider);
  final knowsLikes =
      listAtPress != null &&
      listAtPress.hasValue &&
      !listAtPress.isLoading &&
      !listAtPress.hasError;
  if (user == null || user.isAnonymous) {
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
  if (!context.mounted) return null;
  final notifier = ref.read(likedGamesProvider.notifier);
  final legacyLike =
      legacyLikeId == null
          ? null
          : ref
              .read(likedGamesProvider)
              .valueOrNull
              ?.where((like) => like.sourceGameId == legacyLikeId)
              .firstOrNull;
  final canonicalLiked = notifier.isLiked(likeId);
  final wasLiked = canonicalLiked || legacyLike != null;
  // An outline pressed during loading or sign-in asked to like this game.
  if (!knowsLikes && wasLiked) return null;
  var nowLiked =
      canonicalLiked || legacyLike == null
          ? await notifier.toggle(game)
          : false;
  // Older app versions could save the same game under the Gamebase ID.
  // Remove that saved like too when the viewer unlikes from the board.
  if (!nowLiked && legacyLike != null) {
    nowLiked = !await notifier.removeAnalysis(legacyLike);
  }
  if (!context.mounted) return nowLiked == wasLiked ? null : nowLiked;
  if (nowLiked == wasLiked) {
    showDesktopToast(
      context,
      wasLiked ? "Couldn't remove the like." : "Couldn't like this game.",
      error: true,
    );
    return null;
  }
  if (nowLiked) {
    showDesktopLikeTagOffer(context, game);
  } else {
    showDesktopToast(context, 'Removed from My Likes');
  }
  return nowLiked;
}
