import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';

/// Per-tab tournament focus. Each Tournament-Detail tab has its own entry so
/// the user can keep multiple tournaments open side-by-side and not lose
/// state when switching between them. Keyed by [DesktopTab.id].
final tournamentByTabIdProvider =
    StateProvider<Map<String, GroupEventCardModel>>(
      (_) => const <String, GroupEventCardModel>{},
    );

/// Currently focused tournament for the desktop Tournament Detail pane.
///
/// Derived from [tournamentByTabIdProvider] using whichever tab is active.
/// The detail pane (about / games / standings) reads this to know which
/// tournament to render — same surface as before, the storage just moved
/// from a single global slot to a per-tab map.
final activeTournamentProvider = Provider<GroupEventCardModel?>((ref) {
  final activeId = ref.watch(desktopTabsProvider).activeId;
  if (activeId == null) return null;
  final byTab = ref.watch(tournamentByTabIdProvider);
  return byTab[activeId];
});

final tournamentForTabProvider = Provider.family<GroupEventCardModel?, String>((
  ref,
  tabId,
) {
  final byTab = ref.watch(tournamentByTabIdProvider);
  return byTab[tabId];
});

/// Sub-view shown inside the Tournament Detail pane. Mirrors the mobile
/// segmented switcher (about / games / standings).
enum TournamentDetailSegment { about, games, standings }

extension TournamentDetailSegmentLabel on TournamentDetailSegment {
  String get label {
    switch (this) {
      case TournamentDetailSegment.about:
        return 'About';
      case TournamentDetailSegment.games:
        return 'Games';
      case TournamentDetailSegment.standings:
        return 'Standings';
    }
  }
}

final tournamentDetailSegmentProvider = StateProvider<TournamentDetailSegment>(
  (_) => TournamentDetailSegment.games,
);

final tournamentDetailSegmentByTabIdProvider =
    StateProvider.family<TournamentDetailSegment, String>(
      (_, __) => TournamentDetailSegment.games,
    );

/// Activates a tournament for the desktop Tournament Detail pane:
/// 1. Plain event activation navigates the current tab to the event's Games
///    list, matching browser "same tab" route semantics from the tournament
///    overview;
/// 2. Explicit new-tab activation (Cmd/Ctrl-click, context menu, etc.) opens a
///    separate Tournament-Detail tab for the event;
/// 3. Stores [tournament] in the per-tab map keyed by the destination tab id;
/// 4. Feeds [tournament.id] into mobile's [selectedBroadcastModelProvider],
///    which is what kicks the `tourDetailScreenProvider` chain (rounds,
///    games, standings) into life.
///
/// Do not resolve by [tournamentByTabIdProvider] alone: a Tournament-Detail tab
/// can be converted into a Board tab when the user opens one of its games, and
/// that board tab intentionally keeps stale tournament metadata keyed by the
/// same id. Event-card clicks must still land on the event game-list route, not
/// focus an already-open in-game board tab.
void setActiveTournament(
  WidgetRef ref,
  GroupEventCardModel tournament, {
  bool openInNewTab = false,
}) {
  final tabsNotifier = ref.read(desktopTabsProvider.notifier);

  final String tabId;
  if (openInNewTab) {
    tabId = tabsNotifier.open(
      TabKind.tournamentDetail,
      title: tournament.title,
      reuseExisting: false,
    );
  } else {
    tabId =
        tabsNotifier.navigateActive(
          TabKind.tournamentDetail,
          title: tournament.title,
        ) ??
        tabsNotifier.open(
          TabKind.tournamentDetail,
          title: tournament.title,
          reuseExisting: false,
        );
  }

  ref.read(tournamentByTabIdProvider.notifier).update((existing) {
    return <String, GroupEventCardModel>{...existing, tabId: tournament};
  });
  ref.read(tournamentDetailSegmentByTabIdProvider(tabId).notifier).state =
      TournamentDetailSegment.games;
  // The mobile chain expects a `GroupBroadcast`. Synthesize a minimal one;
  // the downstream notifiers only depend on `id` to fetch tours.
  ref.read(selectedBroadcastModelProvider.notifier).state = GroupBroadcast(
    id: tournament.id,
    createdAt: DateTime.now(),
    name: tournament.title,
    search: const <String>[],
  );
}
