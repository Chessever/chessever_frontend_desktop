import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';

const String tournamentLiveFirstPreferenceKey =
    'desktop_tournaments_live_first_v2';

abstract interface class TournamentLiveFirstStore {
  Future<bool?> read();

  Future<void> write(bool value);
}

class SqliteTournamentLiveFirstStore implements TournamentLiveFirstStore {
  SqliteTournamentLiveFirstStore({AppDatabase? database})
    : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  @override
  Future<bool?> read() => _database.getBool(tournamentLiveFirstPreferenceKey);

  @override
  Future<void> write(bool value) =>
      _database.setBool(tournamentLiveFirstPreferenceKey, value);
}

final tournamentLiveFirstStoreProvider = Provider<TournamentLiveFirstStore>(
  (ref) => SqliteTournamentLiveFirstStore(),
);

final tournamentLiveFirstProvider =
    StateNotifierProvider<TournamentLiveFirstController, bool>((ref) {
      return TournamentLiveFirstController(
        ref.watch(tournamentLiveFirstStoreProvider),
      );
    });

class TournamentLiveFirstController extends StateNotifier<bool> {
  TournamentLiveFirstController(this._store) : super(false) {
    restored = _restore();
  }

  final TournamentLiveFirstStore _store;
  late final Future<void> restored;
  bool _userChanged = false;

  Future<void> _restore() async {
    try {
      final saved = await _store.read();
      if (!mounted || _userChanged || saved == null) return;
      state = saved;
    } catch (error) {
      debugPrint('Tournament Live first preference restore failed: $error');
    }
  }

  Future<void> setEnabled(bool value) async {
    _userChanged = true;
    if (mounted) state = value;
    try {
      await _store.write(value);
    } catch (error) {
      debugPrint('Tournament Live first preference save failed: $error');
    }
  }

  Future<void> toggle() => setEnabled(!state);
}

bool shouldShowTournamentLiveFirst(GroupEventCategory category) =>
    category != GroupEventCategory.past;

/// Returns a display-only ordering without mutating the provider-owned list.
///
/// When [liveFirst] is enabled, verified live broadcasts are promoted as one
/// stable cohort. The existing personalized order remains unchanged inside
/// both the live and non-live cohorts.
List<GroupEventCardModel> orderTournamentEventsForDisplay(
  Iterable<GroupEventCardModel> events, {
  required bool liveFirst,
}) {
  final ordered = events.toList(growable: false);
  if (!liveFirst) return ordered;

  return <GroupEventCardModel>[
    for (final event in ordered)
      if (event.tourEventCategory == TourEventCategory.live) event,
    for (final event in ordered)
      if (event.tourEventCategory != TourEventCategory.live) event,
  ];
}
