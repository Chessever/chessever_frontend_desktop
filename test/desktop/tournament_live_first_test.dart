import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/tournament_live_first_toggle.dart';
import 'package:chessever/providers/group_event_category.dart';
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
    expect(
      RegExp(r'orderTournamentEventsForDisplay\(').allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
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

    var decoration =
        tester.widget<Container>(chromeFinder).decoration! as BoxDecoration;
    expect(decoration.color, kBlack2Color);
    expect(decoration.border!.top.color, kDividerColor);
    expect(
      tester.widget<Text>(find.text('Live first')).style!.color,
      kWhiteColor70,
    );

    await tester.tap(find.text('Live first'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(store.writes, [true]);
    decoration =
        tester.widget<Container>(chromeFinder).decoration! as BoxDecoration;
    expect(decoration.color, kPrimaryColor.withValues(alpha: 0.14));
    expect(decoration.border!.top.color, kPrimaryColor.withValues(alpha: 0.65));
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
