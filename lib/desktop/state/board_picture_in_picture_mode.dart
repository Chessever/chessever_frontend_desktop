import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Whether the current secondary Board window is the compact, always-on-top
/// picture-in-picture surface.
///
/// The primary application window keeps the default `false`. A PiP window owns
/// a separate [ProviderContainer], so enabling this there cannot collapse the
/// board layout in the main window.
final boardPictureInPictureModeProvider = StateProvider<bool>((ref) => false);

/// Main-window view of the one reusable desktop PiP surface.
///
/// Secondary windows own separate provider containers, so this state is
/// intentionally updated by the primary window's PiP coordinator and the
/// cross-window lifecycle channel. Keeping the visible game id lets the
/// in-board PiP action behave like a real toggle for the game it currently
/// controls while still replacing the PiP when another live game is chosen.
@immutable
class BoardPictureInPictureVisibility {
  const BoardPictureInPictureVisibility.hidden()
    : visible = false,
      gameId = null;

  const BoardPictureInPictureVisibility.visible(this.gameId) : visible = true;

  final bool visible;
  final String? gameId;

  bool isShowingGame(String? candidateGameId) {
    final current = gameId?.trim();
    final candidate = candidateGameId?.trim();
    return visible &&
        current != null &&
        current.isNotEmpty &&
        candidate != null &&
        candidate.isNotEmpty &&
        current == candidate;
  }
}

final boardPictureInPictureVisibilityProvider =
    StateProvider<BoardPictureInPictureVisibility>(
      (ref) => const BoardPictureInPictureVisibility.hidden(),
    );
