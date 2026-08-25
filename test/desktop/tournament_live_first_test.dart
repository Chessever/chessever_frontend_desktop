import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/tournament_live_first_toggle.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('corrected preference ignores the pre-release default key', () {
    expect(
      tournamentLiveFirstPreferenceKey,
      'desktop_tournaments_live_first_v2',
    );
  });

  test('Events pane wires Live first before layout controls on both feeds', () {
    final source =
        File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();
    final toggleIndex = source.indexOf('TournamentLiveFirstToggle');
    final layoutIndex = source.indexOf(
      'GameViewModeToggle',
      toggleIndex < 0 ? 0 : toggleIndex,
    );

    expect(toggleIndex, greaterThanOrEqualTo(0));
    expect(layoutIndex, greaterThan(toggleIndex));
    expect(source, contains('_desktopOrderedForYouEventsProvider'));
    expect(source, contains('tournamentLiveGameEventIdsProvider'));
    expect(
      RegExp(r'orderTournamentEventsForDisplay\(').allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
    expect(
      RegExp(r'liveGameEventIds:').allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('Live first reuses the Live filter IDs and Live collection window', () {
    final source =
        File('lib/desktop/state/tournament_live_first.dart').readAsStringSync();
    final gamesSource =
        File(
          'lib/repository/supabase/game/game_repository.dart',
        ).readAsStringSync();

    expect(source, contains('configuredLiveGroupBroadcastIdsProvider'));
    expect(source, contains('forYouLiveFilterEventIdsProvider'));
    expect(source, contains("statusFilters: const ['live']"));
    expect(source, contains('liveFirstGameActivityWindow'));
    expect(gamesSource, contains("'live'"));
    expect(gamesSource, contains("order('last_move_time'"));
    expect(gamesSource, contains("inFilter('group_broadcast_id'"));
  });

  test('live-game detection always sweeps beyond the loaded feed page', () {
    final source =
        File('lib/desktop/state/tournament_live_first.dart').readAsStringSync();

    // For You pages 20 events at a time ordered by rating, so the live event
    // Live first exists to surface is routinely one the feed has not loaded.
    // A query scoped only to the visible rows can never return it.
    final unscopedSweep = source.indexOf('await collect();');
    final scopedSweep = source.indexOf('await collect(eventIds:');
    expect(unscopedSweep, greaterThanOrEqualTo(0));
    expect(scopedSweep, greaterThan(unscopedSweep));
    expect(source, isNot(contains('? visibleIds.toList()')));
  });

  test('Live first hydrates live events the feed has not paged in', () {
    final stateSource =
        File('lib/desktop/state/tournament_live_first.dart').readAsStringSync();
    final paneSource =
        File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();
    final forYouSource =
        File('lib/providers/for_you_games_provider.dart').readAsStringSync();

    expect(stateSource, contains('tournamentLiveEventPrefetchProvider'));
    expect(stateSource, contains('hydrateEvents(liveIds)'));
    expect(
      paneSource,
      contains('ref.watch(tournamentLiveEventPrefetchProvider)'),
    );
    // The prefetch must not wait on the toggle: fetching on tap put two round
    // trips between the click and the resort, so the promotion trailed the
    // button instead of landing with it.
    final prefetchBody = stateSource.substring(
      stateSource.indexOf('final tournamentLiveEventPrefetchProvider'),
      stateSource.indexOf('/// The same event IDs the For You'),
    );
    expect(prefetchBody, isNot(contains('tournamentLiveFirstProvider')));
    expect(forYouSource, contains('Future<void> hydrateEvents('));
    // Hydrated cards must come in through the feed's own pipeline, otherwise
    // the promoted row renders without its board previews.
    expect(
      forYouSource,
      contains('_prefetchTopGameSnapshots(additions, replace: false)'),
    );
    expect(forYouSource, contains('_hydratingEventIds'));
  });

  test('desktop chrome tooltips never install a long-press recognizer', () {
    // An ancestor long-press GestureDetector wins the gesture arena over the
    // button's own tap recognizer past kLongPressTimeout, swallowing slow
    // clicks on every tooltipped desktop control.
    final source =
        File('lib/desktop/widgets/desktop_tooltip.dart').readAsStringSync();
    expect(source, contains('longPress: false'));
  });

  test('shows Live first on For You and Current but not Past', () {
    expect(shouldShowTournamentLiveFirst(GroupEventCategory.forYou), isTrue);
    expect(shouldShowTournamentLiveFirst(GroupEventCategory.current), isTrue);
    expect(shouldShowTournamentLiveFirst(GroupEventCategory.past), isFalse);
  });

  testWidgets('Live first control toggles and persists its state', (
    tester,
  ) async {
    final store = _FakeTournamentLiveFirstStore(readValue: null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [tournamentLiveFirstStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(
          home: Scaffold(body: TournamentLiveFirstToggle()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Live first'), findsOneWidget);
    final chromeFinder = find.byKey(
      const ValueKey<String>('tournament-live-first-chrome'),
    );
    expect(chromeFinder, findsOneWidget);
    expect(
      tester.widget<DesktopToolbarPillButton>(chromeFinder).tone,
      DesktopToolbarPillTone.neutral,
    );

    var decoration =
        tester
                .widget<Container>(
                  find.descendant(
                    of: chromeFinder,
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(decoration.border!.top.color, kDividerColor);
    expect(
      tester.widget<Text>(find.text('Live first')).style!.color,
      kWhiteColor70,
    );

    await tester.tap(find.text('Live first'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(store.writes, [true]);
    expect(
      tester.widget<DesktopToolbarPillButton>(chromeFinder).tone,
      DesktopToolbarPillTone.primary,
    );
    decoration =
        tester
                .widget<Container>(
                  find.descendant(
                    of: chromeFinder,
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.color, kPrimaryColor.withValues(alpha: 0.10));
    expect(decoration.border!.top.color, kPrimaryColor.withValues(alpha: 0.35));
    expect(
      tester.widget<Text>(find.text('Live first')).style!.color,
      kPrimaryColor,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.bolt_rounded)).color,
      kPrimaryColor,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test(
    'restored Live-first choice replaces the normal-order default',
    () async {
      final store = _FakeTournamentLiveFirstStore(readValue: true);
      final controller = TournamentLiveFirstController(store);
      addTearDown(controller.dispose);

      expect(controller.state, isFalse);

      await controller.restored;

      expect(controller.state, isTrue);
    },
  );

  test('a user change wins over a late preference restore', () async {
    final store = _DelayedTournamentLiveFirstStore();
    final controller = TournamentLiveFirstController(store);
    addTearDown(controller.dispose);

    await controller.setEnabled(false);
    store.completeRead(true);
    await controller.restored;

    expect(controller.state, isFalse);
    expect(store.writes, [false]);
  });

  test('live-first ordering is stable and keeps every event', () {
    final events = [
      _event('favorite-ongoing', TourEventCategory.ongoing),
      _event('live-a', TourEventCategory.live),
      _event('upcoming', TourEventCategory.upcoming),
      _event('live-b', TourEventCategory.live),
      _event('completed', TourEventCategory.completed),
    ];

    final ordered = orderTournamentEventsForDisplay(events, liveFirst: true);

    expect(ordered.map((event) => event.id), [
      'live-a',
      'live-b',
      'favorite-ongoing',
      'upcoming',
      'completed',
    ]);
    expect(events.map((event) => event.id), [
      'favorite-ongoing',
      'live-a',
      'upcoming',
      'live-b',
      'completed',
    ]);
  });

  test(
    'live-first promotes events with live games without reordering either cohort',
    () {
      final events = [
        _event('favorite-ongoing', TourEventCategory.ongoing),
        _event('quiet-ongoing', TourEventCategory.ongoing),
        _event('live-from-games', TourEventCategory.ongoing),
        _event('upcoming', TourEventCategory.upcoming),
        _event('live-badge', TourEventCategory.live),
      ];

      final ordered = orderTournamentEventsForDisplay(
        events,
        liveFirst: true,
        liveGameEventIds: const {'live-from-games'},
      );

      expect(ordered.map((event) => event.id), [
        'live-from-games',
        'live-badge',
        'favorite-ongoing',
        'quiet-ongoing',
        'upcoming',
      ]);
    },
  );

  test('fresh live-game activity uses the two-hour games window', () {
    final now = DateTime.utc(2026, 8, 19, 12);

    expect(
      isFreshLiveGame(
        isOngoing: true,
        lastMoveTime: now.subtract(const Duration(minutes: 20)),
        lastMove: 'e2e4',
        now: now,
      ),
      isTrue,
    );
    expect(
      isFreshLiveGame(
        isOngoing: true,
        lastMoveTime: now.subtract(const Duration(hours: 2, minutes: 1)),
        lastMove: 'e2e4',
        now: now,
      ),
      isFalse,
    );
    expect(
      isFreshLiveGame(
        isOngoing: false,
        lastMoveTime: now.subtract(const Duration(minutes: 1)),
        lastMove: 'e2e4',
        now: now,
      ),
      isFalse,
    );
    expect(
      isFreshLiveGame(
        isOngoing: true,
        lastMoveTime: now.subtract(const Duration(minutes: 1)),
        lastMove: '   ',
        now: now,
      ),
      isFalse,
    );
  });

  test('strict live RPC rows keep only non-empty event ids', () {
    expect(
      parseStrictLiveGroupBroadcastIds([
        {'group_broadcast_id': 'event-a'},
        {'group_broadcast_id': ''},
        {'group_broadcast_id': 'event-a'},
        {'other': 'event-b'},
        'ignored',
      ]),
      ['event-a'],
    );
    expect(parseStrictLiveGroupBroadcastIds(null), isEmpty);
  });

  test(
    'Live first reorders from Live-filter IDs even when event badges stay ongoing',
    () {
      final events = [
        _event('favorite-ongoing', TourEventCategory.ongoing),
        _event('live-from-filter', TourEventCategory.ongoing),
        _event('upcoming', TourEventCategory.upcoming),
      ];

      final liveIds = mergeTournamentLiveEventIds(
        configuredIds: const ['live-from-filter'],
        liveFilterIds: const ['live-from-filter'],
      );
      final ordered = orderTournamentEventsForDisplay(
        events,
        liveFirst: true,
        liveGameEventIds: liveIds,
      );

      expect(liveFirstGameActivityWindow, const Duration(hours: 8));
      expect(ordered.map((event) => event.id), [
        'live-from-filter',
        'favorite-ongoing',
        'upcoming',
      ]);
    },
  );

  test('disabled live-first ordering preserves the existing order', () {
    final events = [
      _event('favorite-ongoing', TourEventCategory.ongoing),
      _event('live', TourEventCategory.live),
      _event('upcoming', TourEventCategory.upcoming),
    ];

    final ordered = orderTournamentEventsForDisplay(events, liveFirst: false);

    expect(ordered.map((event) => event.id), [
      'favorite-ongoing',
      'live',
      'upcoming',
    ]);
  });
}

class _FakeTournamentLiveFirstStore implements TournamentLiveFirstStore {
  _FakeTournamentLiveFirstStore({required this.readValue});

  final bool? readValue;
  final List<bool> writes = <bool>[];

  @override
  Future<bool?> read() async => readValue;

  @override
  Future<void> write(bool value) async {
    writes.add(value);
  }
}

class _DelayedTournamentLiveFirstStore implements TournamentLiveFirstStore {
  final _read = Completer<bool?>();
  final List<bool> writes = <bool>[];

  void completeRead(bool? value) => _read.complete(value);

  @override
  Future<bool?> read() => _read.future;

  @override
  Future<void> write(bool value) async {
    writes.add(value);
  }
}

GroupEventCardModel _event(String id, TourEventCategory category) {
  return GroupEventCardModel(
    id: id,
    title: id,
    dates: '',
    maxAvgElo: 2500,
    timeUntilStart: '',
    tourEventCategory: category,
    timeControl: 'Standard',
    endDate: null,
    startDate: null,
  );
}
