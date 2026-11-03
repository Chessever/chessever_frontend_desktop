import 'dart:async';
import 'package:chessever/repository/supabase/base_repository.dart';
import 'package:chessever/repository/supabase/settings/settings.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:hooks_riverpod/hooks_riverpod.dart';

// providers.dart
final settingsRepositoryProvider = AutoDisposeProvider<SettingsRepository>(
  (ref) => SettingsRepository(),
);

final liveSettingsProvider = AutoDisposeStreamProvider<Settings?>(
  (ref) => ref.read(settingsRepositoryProvider).subscribeToSettings(),
);

class SettingsRepository extends BaseRepository {
  Future<Settings?> getSettings() => handleApiCall(() async {
    final response = await supabase.from('settings').select().maybeSingle();
    return response != null ? Settings.fromJson(response) : null;
  });

  Stream<Settings?> subscribeToSettings() => supabase
      .from('settings')
      .stream(primaryKey: ['id'])
      .map((data) => data.isEmpty ? null : Settings.fromJson(data.first));

  Stream<List<String>> subscribeToLiveRoundIds() => supabase
      .from('settings')
      .stream(primaryKey: ['id'])
      .map(
        (data) =>
            data.isEmpty
                ? <String>[]
                : List<String>.from(data.first['live_round_ids'] ?? []),
      )
      // The row is rewritten every few seconds during live rounds; only a
      // real change to this column should reach (and rebuild) listeners.
      .distinct(listEquals);

  Stream<List<String>> subscribeToLiveTourIds() => supabase
      .from('settings')
      .stream(primaryKey: ['id'])
      .map(
        (data) =>
            data.isEmpty
                ? <String>[]
                : List<String>.from(data.first['live_tour_ids'] ?? []),
      )
      .distinct(_sameStringSet);

  Stream<List<String>> subscribeToLiveGroupBroadcastIds() => supabase
      .from('settings')
      .stream(primaryKey: ['id'])
      .map(
        (data) =>
            data.isEmpty
                ? <String>[]
                : List<String>.from(
                  data.first['live_group_broadcast_ids'] ?? [],
                ),
      )
      .distinct(listEquals);
}

bool _sameStringSet(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final aSet = a.toSet();
  if (aSet.length != b.toSet().length) return false;
  return b.every(aSet.contains);
}
