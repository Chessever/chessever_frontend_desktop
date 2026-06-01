import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// Scoped per tour id. Each tournament has its own "Focus on live games /
// Show finished / Show all" preference, defaulting to `all`. State must not
// bleed across tournaments, otherwise a Live filter in one event silently hides
// finished games in the next event opened from the desktop shell.
//
// Within a single tournament the family entry is kept alive across tab swipes
// and category-dropdown changes (both republish `tourDetailScreenProvider` and
// tear down the screen notifier), so the toggle still sticks while the user
// stays in that event. `tournament_detail_screen` invalidates the family on
// deactivate so leaving the event resets the preference on mobile.
final gameDisplayModeProvider = StateProvider.family<GameDisplayMode, String>(
  (ref, tourId) => GameDisplayMode.all,
);
