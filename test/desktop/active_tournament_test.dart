import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/panes/tournament_detail_pane.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';

void main() {
  testWidgets(
    'plain tournament activation navigates the current tab to games',
    (tester) async {
      late DesktopTabsState tabsState;
      late Map<String, GroupEventCardModel> tournamentByTab;
      late TournamentDetailSegment selectedSegment;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                return TextButton(
                  onPressed: () {
                    setActiveTournament(ref, _event());
                    tabsState = ref.read(desktopTabsProvider);
                    tournamentByTab = ref.read(tournamentByTabIdProvider);
                    selectedSegment = ref.read(
                      tournamentDetailSegmentByTabIdProvider(
                        tabsState.activeId!,
                      ),
                    );
                  },
                  child: const Text('run'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('run'));
      await tester.pump();

      expect(tabsState.activeId, 'tournaments-default');
      expect(tabsState.active?.kind, TabKind.tournamentDetail);
      expect(tabsState.active?.title, '12th Serbian Cup');
      expect(tournamentByTab['tournaments-default']?.id, 'event-1');
      expect(selectedSegment, TournamentDetailSegment.games);
    },
  );

  testWidgets(
    'event activation ignores stale tournament metadata on board tabs',
    (tester) async {
      late String boardTabId;
      late String overviewTabId;
      late DesktopTabsState tabsState;
      late Map<String, GroupEventCardModel> tournamentByTab;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                return TextButton(
                  onPressed: () {
                    final tabs = ref.read(desktopTabsProvider.notifier);
                    setActiveTournament(ref, _event());
                    boardTabId = openBoardGameTab(
                      ref,
                      const BoardTabGameArgs(
                        gameId: 'game-1',
                        pgn: '',
                        label: 'Nestorovic vs Bryakin',
                        whiteName: 'Nestorovic, Dejan',
                        blackName: 'Bryakin, Mikhail',
                        tournamentTitle: '12th Serbian Cup',
                      ),
                      replaceActive: true,
                    );
                    overviewTabId = tabs.open(
                      TabKind.tournaments,
                      title: 'Tournaments',
                      reuseExisting: false,
                    );

                    setActiveTournament(ref, _event());
                    tabsState = ref.read(desktopTabsProvider);
                    tournamentByTab = ref.read(tournamentByTabIdProvider);
                  },
                  child: const Text('run'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('run'));
      await tester.pump();

      expect(boardTabId, 'tournaments-default');
      expect(overviewTabId, isNot(boardTabId));
      expect(tabsState.activeId, overviewTabId);
      expect(tabsState.active?.kind, TabKind.tournamentDetail);
      expect(tournamentByTab[boardTabId]?.id, 'event-1');
      expect(tournamentByTab[overviewTabId]?.id, 'event-1');
      expect(
        tabsState.tabs.firstWhere((tab) => tab.id == boardTabId).kind,
        TabKind.board,
      );
    },
  );

  testWidgets('explicit new-tab tournament activation opens a separate tab', (
    tester,
  ) async {
    late DesktopTabsState tabsState;
    late Map<String, GroupEventCardModel> tournamentByTab;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                onPressed: () {
                  setActiveTournament(ref, _event(), openInNewTab: true);
                  tabsState = ref.read(desktopTabsProvider);
                  tournamentByTab = ref.read(tournamentByTabIdProvider);
                },
                child: const Text('run'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('run'));
    await tester.pump();

    expect(tabsState.tabs, hasLength(2));
    expect(tabsState.activeId, isNot('tournaments-default'));
    expect(tabsState.active?.kind, TabKind.tournamentDetail);
    expect(tournamentByTab[tabsState.activeId]?.id, 'event-1');
    expect(
      tabsState.tabs.firstWhere((tab) => tab.id == 'tournaments-default').kind,
      TabKind.tournaments,
    );
  });

  testWidgets(
    'retained tournament tab restores its event context on A to B to A',
    (tester) async {
      final tabs = DesktopTabsNotifier();
      final tabA =
          tabs.navigateActive(TabKind.tournamentDetail, title: 'Event A')!;
      final tabB = tabs.open(
        TabKind.tournamentDetail,
        title: 'Event B',
        reuseExisting: false,
        focus: false,
      );
      final eventA = _event(id: 'event-a', title: 'Event A');
      final eventB = _event(id: 'event-b', title: 'Event B');
      late WidgetRef ref;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopTabsProvider.overrideWith((ref) => tabs),
            tournamentByTabIdProvider.overrideWith(
              (ref) => {tabA: eventA, tabB: eventB},
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, widgetRef, _) {
                ref = widgetRef;
                final state = widgetRef.watch(desktopTabsProvider);
                final activeIndex = state.tabs.indexWhere(
                  (tab) => tab.id == state.activeId,
                );
                return PersistentIndexedStack(
                  index: activeIndex,
                  children: [
                    TournamentDetailContextOwner(tabId: tabA),
                    TournamentDetailContextOwner(tabId: tabB),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(ref.read(selectedBroadcastModelProvider)?.id, 'event-a');

      tabs.activate(tabB);
      await tester.pump();
      await tester.pump();
      expect(ref.read(selectedBroadcastModelProvider)?.id, 'event-b');

      tabs.activate(tabA);
      await tester.pump();
      await tester.pump();
      expect(ref.read(selectedBroadcastModelProvider)?.id, 'event-a');

      await tester.pump();
      expect(
        ref.read(selectedBroadcastModelProvider)?.id,
        'event-a',
        reason: 'the retained inactive B owner must not write context back',
      );
    },
  );
}

GroupEventCardModel _event({String id = 'event-1', String? title}) {
  return GroupEventCardModel(
    id: id,
    title: title ?? '12th Serbian Cup',
    dates: 'May 21 - 24, 2026',
    maxAvgElo: 2351,
    timeUntilStart: 'Ongoing',
    tourEventCategory: TourEventCategory.ongoing,
    timeControl: 'Standard',
    endDate: DateTime.utc(2026, 5, 24),
    startDate: DateTime.utc(2026, 5, 21),
  );
}
