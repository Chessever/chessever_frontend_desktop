import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';

/// Smart game collection selected for each desktop tab.
final desktopSmartGamesTypeByTabIdProvider =
    StateProvider<Map<String, PremiumGamesType>>((ref) => const {});
