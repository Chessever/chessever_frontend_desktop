import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/live_first_mark.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// The day-grouped game lists that carry a one-click Live first toggle.
enum GameListLiveFirstSurface { countrymen, favorites }

/// Whether a game list brings its live games to the top of each day.
///
/// Kept for the session per surface, so leaving Countrymen and coming back
/// keeps the choice. The order itself is applied where each list is grouped
/// into days (`buildDesktopGameDateGroups(liveFirst: ...)`), the one place
/// these lists are sorted.
final gameListLiveFirstProvider =
    StateProvider.family<bool, GameListLiveFirstSurface>(
      (ref, surface) => false,
    );

/// Message shown when Live first is pressed while nothing is in play.
const String kNoLiveGamesRightNowMessage = 'No live games right now';

/// Presses the Live first toggle for [surface].
///
/// Turning it off always works. Turning it on needs a live game in [games]
/// (the list as it is filtered on screen): with none, the toggle stays off
/// and a toast says there are no live games right now, so the press is
/// never silently a no-op.
void pressGameListLiveFirst({
  required BuildContext context,
  required WidgetRef ref,
  required GameListLiveFirstSurface surface,
  required Iterable<GamesTourModel> games,
}) {
  final controller = ref.read(gameListLiveFirstProvider(surface).notifier);
  if (controller.state) {
    controller.state = false;
    return;
  }
  if (!games.any((game) => GameFilterHelper.isLiveNow(game))) {
    showDesktopToast(
      context,
      kNoLiveGamesRightNowMessage,
      icon: const LiveFirstMark(size: 18, color: kWhiteColor70),
    );
    return;
  }
  controller.state = true;
}
