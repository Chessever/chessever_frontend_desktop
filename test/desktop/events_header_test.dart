import 'dart:async';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_collection_cards.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/repository/local_storage/group_broadcast/group_broadcast_local_storage.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _BotvinnikOff extends BotvinnikEnabledNotifier {
  @override
  Future<bool> build() async => false;
}

class _ForYou extends StateNotifier<ForYouState> implements ForYouNotifier {
  _ForYou() : super(const ForYouState(isLoading: true));

  void publish(ForYouState value) => state = value;

  @override
  Future<void> refreshIfStale({
    Duration maxAge = const Duration(minutes: 5),
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Favorites extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => const [];
}

class _FavoriteEvents extends FavoriteEventsNotifier {
  @override
  Future<List<FavoriteEvent>> build() async => const [];
}

class _BroadcastStorage extends GroupBroadcastLocalStorage {
  _BroadcastStorage({
    required super.ref,
    required super.category,
    required this.fetch,
  });
  final Future<List<GroupBroadcast>> Function() fetch;
  @override
  Future<List<GroupBroadcast>> fetchGroupBroadcasts() => fetch();
  @override
  Future<List<GroupBroadcast>> refresh() => fetch();
}

class _LiveFirstStore implements TournamentLiveFirstStore {
  @override
  Future<bool?> read() async => false;

  @override
  Future<void> write(bool value) async {}
}

void main() {
  setUpAll(() async {
    for (final entry
        in {
          FThemes.zinc.dark.typography.defaultFontFamily:
              'packages/forui/assets/fonts/inter/Inter-Regular.ttf',
          'Geist': 'assets/fonts/Geist-VariableFont_wght.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(rootBundle.load(entry.value));
      await loader.load();
    }
  });

  testWidgets(
    'collection header stays above toolbar across modes and feed states',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final forYou = _ForYou();
      var result = Completer<List<GroupBroadcast>>();
      final container = ProviderContainer(
        overrides: [
          botvinnikEnabledProvider.overrideWith(_BotvinnikOff.new),
          forYouEventsProvider.overrideWith((_) => forYou),
          groupBroadcastLocalStorage.overrideWith(
            (ref, category) => _BroadcastStorage(
              ref: ref,
              category: category,
              fetch: () => result.future,
            ),
          ),
          liveGroupBroadcastIdsProvider.overrideWith(
            (_) => Stream.value(const <String>[]),
          ),
          tournamentLiveEventPrefetchProvider.overrideWith((_) {}),
          tournamentLiveFirstStoreProvider.overrideWithValue(_LiveFirstStore()),
          favoritePlayersProviderNew.overrideWith(_Favorites.new),
          favoriteEventsProvider.overrideWith(_FavoriteEvents.new),
          effectiveCountryProvider.overrideWithValue(
            const AsyncValue.loading(),
          ),
        ],
      );
      addTearDown(container.dispose);
      // Keep the controlled notifier alive while Current/Past stop watching it.
      final forYouSubscription = container.listen(
        forYouEventsProvider,
        (_, _) {},
      );
      addTearDown(forYouSubscription.close);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
            ),
            builder:
                (_, child) => FTheme(data: FThemes.zinc.dark, child: child!),
            home: Builder(
              builder: (context) {
                ResponsiveHelper.init(context);
                return const Scaffold(
                  backgroundColor: kBackgroundColor,
                  body: TournamentsPane(tabId: 'events'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final cards = find.byType(DesktopCollectionCards);
      final tabs = find.byType(DesktopSegmentedTabs<GroupEventCategory>);
      void expectHeader([Rect? original]) {
        expect(cards, findsOneWidget);
        final rect = tester.getRect(cards);
        expect(rect.bottom, lessThanOrEqualTo(tester.getTopLeft(tabs).dy));
        if (original != null) expect(rect, original);
        expect(tester.takeException(), isNull);
      }

      expectHeader();
      final headerRect = tester.getRect(cards);
      final headerElement = tester.element(cards);
      for (final category in ['Current', 'Past', 'For You']) {
        await tester.tap(find.text(category));
        await tester.pump(const Duration(milliseconds: 400));
        if (!result.isCompleted) {
          result.complete(const []);
          await tester.pump();
          await tester.pump();
        }
        expectHeader(headerRect);
        expect(tester.element(cards), same(headerElement));
      }

      forYou.publish(const ForYouState(error: 'temporary feed error'));
      await tester.pump();
      expectHeader(headerRect);
      forYou.publish(const ForYouState(isLoading: false, hasMore: false));
      await tester.pump();
      expectHeader(headerRect);

      result = Completer<List<GroupBroadcast>>();
      await tester.tap(find.text('Current'));
      await tester.pump();
      result.completeError(StateError('temporary event error'));
      await tester.pump();
      await tester.pump();
      expectHeader(headerRect);

      result = Completer<List<GroupBroadcast>>()..complete(const []);
      container.invalidate(groupEventScreenProvider);
      await tester.pump();
      await tester.pump();
      expectHeader(headerRect);

      // The fixed-height collection shelf remains horizontally scrollable.
      tester.view.physicalSize = const Size(900, 600);
      await tester.pump();
      expectHeader();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );
}
