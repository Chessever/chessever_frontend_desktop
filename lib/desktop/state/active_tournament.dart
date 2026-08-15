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

/// Sub-view shown inside the Tournament Detail pane.
enum TournamentDetailSegment { about, games, bracket, standings }

enum TournamentDetailLayout { regular, individualKnockout, team }

bool canCommitTournamentBracketOpen({
  required DesktopTabsState tabs,
  required String originTabId,
  required String? originEventId,
  required String expectedEventId,
  required String expectedTourId,
  required String? selectedBroadcastId,
  required String? resolvedTourId,
  required TournamentDetailSegment currentSegment,
  required int expectedEpoch,
  required int currentEpoch,
}) =>
    tabs.activeId == originTabId &&
    tabs.active?.kind == TabKind.tournamentDetail &&
    originEventId == expectedEventId &&
    selectedBroadcastId == expectedEventId &&
    resolvedTourId == expectedTourId &&
    currentSegment == TournamentDetailSegment.bracket &&
    currentEpoch == expectedEpoch;

extension TournamentDetailSegmentLabel on TournamentDetailSegment {
  String get label {
    switch (this) {
      case TournamentDetailSegment.about:
        return 'About';
      case TournamentDetailSegment.games:
        return 'Games';
      case TournamentDetailSegment.bracket:
        return 'Bracket';
      case TournamentDetailSegment.standings:
        return 'Standings';
    }
  }
}

const _regularTournamentDetailSegments = <TournamentDetailSegment>[
  TournamentDetailSegment.about,
  TournamentDetailSegment.games,
  TournamentDetailSegment.standings,
];

const _knockoutTournamentDetailSegments = <TournamentDetailSegment>[
  TournamentDetailSegment.about,
  TournamentDetailSegment.games,
  TournamentDetailSegment.bracket,
  TournamentDetailSegment.standings,
];

List<TournamentDetailSegment> tournamentDetailSegmentsForLayout(
  TournamentDetailLayout layout,
) => switch (layout) {
  TournamentDetailLayout.individualKnockout =>
    _knockoutTournamentDetailSegments,
  TournamentDetailLayout.regular ||
  TournamentDetailLayout.team => _regularTournamentDetailSegments,
};

/// Visible Desktop tournament-detail segments for the resolved competition
/// type. Individual knockout is the only layout that exposes Bracket; team and
/// ordinary events retain the established three-segment Desktop surface.
List<TournamentDetailSegment> tournamentDetailSegmentsFor({
  required bool isKnockout,
  required bool isTeamEvent,
}) => tournamentDetailSegmentsForLayout(
  tournamentDetailLayoutForDetection(
    isTeam: isTeamEvent,
    isKnockout: isKnockout,
  ),
);

TournamentDetailLayout tournamentDetailLayoutForDetection({
  required bool isTeam,
  required bool isKnockout,
}) {
  if (isTeam) return TournamentDetailLayout.team;
  if (isKnockout) return TournamentDetailLayout.individualKnockout;
  return TournamentDetailLayout.regular;
}

TournamentDetailLayout provisionalTournamentDetailLayoutForSegment(
  TournamentDetailSegment segment,
) => switch (segment) {
  TournamentDetailSegment.bracket => TournamentDetailLayout.individualKnockout,
  TournamentDetailSegment.about ||
  TournamentDetailSegment.games ||
  TournamentDetailSegment.standings => TournamentDetailLayout.regular,
};

/// Remembers the structural layout independently for each selected tour.
///
/// Detection can briefly return its default while providers reload. Once a
/// tour resolves as team or individual knockout, a pending emission therefore
/// cannot make Bracket flicker away. A new category ID resolves independently.
class TournamentDetailLayoutTracker {
  final Map<String, TournamentDetailLayout> _layoutsByTour = {};

  String? _activeTourId;

  TournamentDetailLayout resolve({
    required String? tourId,
    bool isTeam = false,
    bool isKnockout = false,
    bool isDetectionPending = false,
    TournamentDetailLayout unresolvedLayout = TournamentDetailLayout.regular,
  }) {
    final normalizedTourId = tourId?.trim();
    if (normalizedTourId != null && normalizedTourId.isNotEmpty) {
      _activeTourId = normalizedTourId;
      final detected = tournamentDetailLayoutForDetection(
        isTeam: isTeam,
        isKnockout: isKnockout,
      );
      final remembered = _layoutsByTour[normalizedTourId];

      if (!isDetectionPending) {
        final shouldRemember =
            remembered == null ||
            (detected == TournamentDetailLayout.team &&
                remembered != TournamentDetailLayout.team) ||
            (remembered == TournamentDetailLayout.regular &&
                detected == TournamentDetailLayout.individualKnockout);
        if (shouldRemember) {
          _layoutsByTour[normalizedTourId] = detected;
        }
      }

      if (remembered == null && isDetectionPending) {
        return unresolvedLayout;
      }
    }

    final activeTourId = _activeTourId;
    if (activeTourId == null) return TournamentDetailLayout.regular;
    return _layoutsByTour[activeTourId] ?? TournamentDetailLayout.regular;
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
