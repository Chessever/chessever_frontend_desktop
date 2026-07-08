import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/player_stats_repository.dart';

final playerStatsRepositoryProvider = Provider<PlayerStatsRepository>(
  (_) => PlayerStatsRepository(),
);

/// Value-equal key for [playerStatsProvider]. [revision] busts the cache when
/// the underlying games change (a sync or a combined rebuild) even though the
/// database path stays constant. [windowDays] scopes the whole dashboard to the
/// last N days of the player's activity (relative to their most recent game),
/// or all-time when null.
@immutable
class PlayerStatsRequest {
  const PlayerStatsRequest({
    required this.databasePath,
    required this.aliases,
    this.playerFideId,
    this.revision = 0,
    this.windowDays,
  });

  final String databasePath;
  final List<String> aliases;
  final String? playerFideId;
  final int revision;
  final int? windowDays;

  @override
  bool operator ==(Object other) {
    return other is PlayerStatsRequest &&
        other.databasePath == databasePath &&
        other.playerFideId == playerFideId &&
        other.revision == revision &&
        other.windowDays == windowDays &&
        listEquals(other.aliases, aliases);
  }

  @override
  int get hashCode => Object.hash(
    databasePath,
    playerFideId,
    revision,
    windowDays,
    Object.hashAll(aliases),
  );
}

final playerStatsProvider = FutureProvider.autoDispose
    .family<PlayerStatsSnapshot, PlayerStatsRequest>((ref, request) async {
      final repository = ref.watch(playerStatsRepositoryProvider);
      return repository.computePlayerStats(
        databasePath: request.databasePath,
        aliases: request.aliases,
        playerFideId: request.playerFideId,
        windowDays: request.windowDays,
      );
    });
