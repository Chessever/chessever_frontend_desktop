import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/utils/country_utils.dart';

/// Args for a Player Profile tab. Mirrors the public surface of
/// `PlayerProfileScreen` so we can rebuild the screen verbatim per tab.
class PlayerProfileArgs {
  const PlayerProfileArgs({
    required this.playerName,
    this.fideId,
    this.title,
    this.federation,
    this.rating,
    this.dataSource = PlayerProfileDataSource.twic,
    this.gamebasePlayerId,
  });

  final String playerName;
  final int? fideId;
  final String? title;
  final String? federation;
  final int? rating;
  final PlayerProfileDataSource dataSource;
  final String? gamebasePlayerId;
}

/// Per-tab player-score-card args, keyed by [DesktopTab.id]. Mirrors the
/// `tournamentByTabIdProvider` pattern so users can open multiple score
/// cards side-by-side without them stepping on each other.
final playerScoreCardByTabIdProvider =
    StateProvider<Map<String, PlayerStandingModel>>(
      (_) => const <String, PlayerStandingModel>{},
    );

class PlayerScoreCardTabContext {
  const PlayerScoreCardTabContext({
    required this.hasEventContext,
    required this.profileDataSource,
    this.gamesContext,
    this.selectedBroadcast,
  });

  final List<GamesTourModel>? gamesContext;
  final bool hasEventContext;
  final PlayerProfileDataSource profileDataSource;
  final GroupBroadcast? selectedBroadcast;
}

/// Per-tab score-card context. The legacy mobile score card stores the active
/// event/list context in globals; desktop tabs need a snapshot so reopening a
/// player from a board game cannot inherit an unrelated "all games" context.
final playerScoreCardContextByTabIdProvider =
    StateProvider<Map<String, PlayerScoreCardTabContext>>(
      (_) => const <String, PlayerScoreCardTabContext>{},
    );

/// Per-tab player-profile args, keyed by [DesktopTab.id].
final playerProfileByTabIdProvider =
    StateProvider<Map<String, PlayerProfileArgs>>(
      (_) => const <String, PlayerProfileArgs>{},
    );

/// Open (or reactivate) a Score Card tab focused on [player]. Mirrors
/// what mobile does when the user taps a player chip on the chessboard:
///  1. Stash a per-tab copy of the player so swapping tabs doesn't lose
///     state.
///  2. Push the same player onto the legacy `selectedPlayerProvider`
///     (which the shared mobile `ScoreCardScreen` reads).
///  3. Activate the relevant tab.
///
/// If a tab already hosts this exact player (matched by name + fideId),
/// it's reactivated instead of duplicated.
String openPlayerScoreCard(
  WidgetRef ref,
  PlayerStandingModel player, {
  bool fromTournamentContext = true,
  bool focus = true,
}) {
  final tabsNotifier = ref.read(desktopTabsProvider.notifier);
  final tabsState = ref.read(desktopTabsProvider);
  final byTab = ref.read(playerScoreCardByTabIdProvider);

  String? existingTabId;
  for (final entry in byTab.entries) {
    final p = entry.value;
    if (p.name == player.name &&
        p.fideId == player.fideId &&
        _tabStillHostsKind(tabsState, entry.key, TabKind.playerScoreCard)) {
      existingTabId = entry.key;
      break;
    }
  }

  final String tabId;
  if (existingTabId != null) {
    if (focus) tabsNotifier.activate(existingTabId);
    tabId = existingTabId;
  } else {
    tabId = tabsNotifier.open(
      TabKind.playerScoreCard,
      title: player.name.isEmpty ? 'Score Card' : player.name,
      reuseExisting: false,
      focus: focus,
    );
  }

  ref
      .read(playerScoreCardByTabIdProvider.notifier)
      .update((m) => <String, PlayerStandingModel>{...m, tabId: player});
  ref
      .read(playerScoreCardContextByTabIdProvider.notifier)
      .update(
        (m) => <String, PlayerScoreCardTabContext>{
          ...m,
          tabId: PlayerScoreCardTabContext(
            gamesContext: ref.read(scoreCardGamesContextProvider),
            hasEventContext: fromTournamentContext,
            profileDataSource: ref.read(
              scoreCardPlayerProfileDataSourceProvider,
            ),
            selectedBroadcast: ref.read(selectedBroadcastModelProvider),
          ),
        },
      );

  // Mirror onto the legacy global the shared `ScoreCardScreen` reads.
  ref.read(selectedPlayerProvider.notifier).state = player;
  // Tournament context drives whether the score card calculates per-event
  // performance. Tapping a player from a board game is "from tournament".
  ref.read(scoreCardHasEventContextProvider.notifier).state =
      fromTournamentContext;
  return tabId;
}

/// Open (or reactivate) a Player Profile tab. Pairs with the score card's
/// "View profile" path.
String openPlayerProfile(
  WidgetRef ref,
  PlayerProfileArgs args, {
  bool focus = true,
}) {
  final tabsNotifier = ref.read(desktopTabsProvider.notifier);
  final tabsState = ref.read(desktopTabsProvider);
  final byTab = ref.read(playerProfileByTabIdProvider);
  final tabTitle = _playerProfileTabTitle(args);

  String? existingTabId;
  for (final entry in byTab.entries) {
    final a = entry.value;
    if (a.playerName == args.playerName &&
        a.fideId == args.fideId &&
        _tabStillHostsKind(tabsState, entry.key, TabKind.playerProfile)) {
      existingTabId = entry.key;
      break;
    }
  }

  final String tabId;
  if (existingTabId != null) {
    if (focus) tabsNotifier.activate(existingTabId);
    tabId = existingTabId;
    tabsNotifier.rename(tabId, title: tabTitle);
  } else {
    tabId = tabsNotifier.open(
      TabKind.playerProfile,
      title: tabTitle,
      reuseExisting: false,
      focus: focus,
    );
  }

  ref
      .read(playerProfileByTabIdProvider.notifier)
      .update((m) => <String, PlayerProfileArgs>{...m, tabId: args});
  return tabId;
}

bool _tabStillHostsKind(
  DesktopTabsState tabsState,
  String tabId,
  TabKind expectedKind,
) {
  for (final tab in tabsState.tabs) {
    if (tab.id == tabId) return tab.kind == expectedKind;
  }
  return false;
}

String _playerProfileTabTitle(PlayerProfileArgs args) {
  final parts = <String>[];
  final flag = CountryUtils.toFlagEmoji(args.federation?.trim() ?? '');
  if (flag.isNotEmpty) parts.add(flag);

  final title = args.title?.trim() ?? '';
  if (title.isNotEmpty) parts.add(title);

  final lastName = _playerProfileLastName(args.playerName);
  parts.add(lastName.isEmpty ? 'Profile' : lastName);
  return parts.join(' ');
}

String _playerProfileLastName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.contains(',')) return trimmed.split(',').first.trim();
  final parts = trimmed.split(RegExp(r'\s+'));
  return parts.isEmpty ? trimmed : parts.last.trim();
}
