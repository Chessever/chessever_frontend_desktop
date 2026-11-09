import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/widgets/event_card/event_image_provider.dart';
import 'package:chessever/widgets/event_card/event_next_round_provider.dart';

/// Detached, bounded public production-query projection. The caller decodes
/// GroupBroadcast/Games with the existing decoders, builds snapshots with
/// buildForYouTopGamesSnapshot, and applies the existing neutral sort. This
/// object neither fetches nor personalizes nor invents any rows/positions.
/// Missing results stay loading. Empty AsyncData means genuinely resolved empty.
class SignedOutEventsPresentationData {
  SignedOutEventsPresentationData({
    required this.capturedAt,
    required this.forYouEvents,
    this.currentEvents = const AsyncValue.loading(),
    this.pastEvents = const AsyncValue.loading(),
    this.selectedCategory = GroupEventCategory.forYou,
    this.viewMode = GamesListViewMode.chessBoardGrid,
    Map<String, ForYouEventGamesSnapshot> snapshots = const {},
    Map<String, EventImageData> artwork = const {},
    Map<String, NextRoundInfo> nextRounds = const {},
  }) : snapshots = Map.unmodifiable(snapshots),
       artwork = Map.unmodifiable(artwork),
       nextRounds = Map.unmodifiable(nextRounds);

  final DateTime capturedAt;
  final GroupEventCategory selectedCategory;
  final GamesListViewMode viewMode;
  final AsyncValue<List<GroupEventCardModel>> forYouEvents;
  final AsyncValue<List<GroupEventCardModel>> currentEvents;
  final AsyncValue<List<GroupEventCardModel>> pastEvents;
  final Map<String, ForYouEventGamesSnapshot> snapshots;
  final Map<String, EventImageData> artwork;
  final Map<String, NextRoundInfo> nextRounds;

  AsyncValue<List<GroupEventCardModel>> get selectedEvents =>
      switch (selectedCategory) {
        GroupEventCategory.forYou => forYouEvents,
        GroupEventCategory.current => currentEvents,
        GroupEventCategory.past => pastEvents,
        GroupEventCategory.search => AsyncValue.error(
          StateError('Search is not part of the signed-out Events projection'),
          StackTrace.empty,
        ),
      };

  ForYouState get forYouState => forYouEvents.when(
    skipLoadingOnRefresh: false,
    skipLoadingOnReload: false,
    data: (events) => ForYouState(events: events, hasMore: false),
    loading: () => const ForYouState(isLoading: true, hasMore: false),
    error: (error, _) => ForYouState(error: error.toString(), hasMore: false),
  );

  AsyncValue<ForYouEventGamesSnapshot> snapshotFor(String eventId) {
    final snapshot = snapshots[eventId];
    return snapshot == null
        ? const AsyncValue.loading()
        : AsyncValue.data(snapshot);
  }
}

/// Only installed by TournamentsPane(readOnlyPresentation: true). A present
/// scope with null data is still inert and loading, never a provider fallback.
class SignedOutEventsPresentationScope extends InheritedWidget {
  const SignedOutEventsPresentationScope({
    super.key,
    required this.data,
    required super.child,
  });

  final SignedOutEventsPresentationData? data;

  static SignedOutEventsPresentationScope? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<
            SignedOutEventsPresentationScope
          >();

  @override
  bool updateShouldNotify(SignedOutEventsPresentationScope oldWidget) =>
      !identical(data, oldWidget.data);
}
