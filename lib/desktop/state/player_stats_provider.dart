import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_stats_repository.dart';

final playerStatsRepositoryProvider = Provider<PlayerStatsRepository>(
  (_) => PlayerStatsRepository(),
);

/// Value-equal key for [playerStatsProvider]. [revision] busts the cache when
/// the underlying games change (a sync or a combined rebuild) even though the
/// database path stays constant. [windowDays] scopes the whole dashboard to the
/// last N days of the player's activity (relative to their most recent game),
/// or all-time when null.
/// Player-centric result scope for the Overview dashboard (W/D/L chips).
enum PlayerStatsOutcomeFilter { all, win, draw, loss }

@immutable
class PlayerStatsRequest {
  const PlayerStatsRequest({
    required this.databasePath,
    required this.aliases,
    this.playerFideId,
    this.revision = 0,
    this.windowDays,
    this.timeControlCategory,
    this.preferredRatingTimeControl,
    this.unclassifiedTimeControlCategory,
    this.playerOutcome = PlayerStatsOutcomeFilter.all,
    this.playerColor,
  });

  final String databasePath;
  final List<String> aliases;
  final String? playerFideId;
  final int revision;
  final int? windowDays;

  /// When set, every dashboard metric is scoped to this time-control category
  /// (e.g. `classical`, `blitz`). Null = all time controls.
  final String? timeControlCategory;

  /// Preferred ladder for the rating chart when [timeControlCategory] is null
  /// ("All"). Online sources default to blitz; Combined/ChessEver to classical.
  final String? preferredRatingTimeControl;

  /// Trusted source-specific fallback for games with no classified clock.
  final String? unclassifiedTimeControlCategory;

  /// When not [PlayerStatsOutcomeFilter.all], every metric is wins/draws/losses
  /// only from the player's point of view.
  final PlayerStatsOutcomeFilter playerOutcome;

  /// When `white` or `black`, metrics only include games the player played
  /// that side. Null = both colours.
  final String? playerColor;

  @override
  bool operator ==(Object other) {
    return other is PlayerStatsRequest &&
        other.databasePath == databasePath &&
        other.playerFideId == playerFideId &&
        other.revision == revision &&
        other.windowDays == windowDays &&
        other.timeControlCategory == timeControlCategory &&
        other.preferredRatingTimeControl == preferredRatingTimeControl &&
        other.unclassifiedTimeControlCategory ==
            unclassifiedTimeControlCategory &&
        other.playerOutcome == playerOutcome &&
        other.playerColor == playerColor &&
        listEquals(other.aliases, aliases);
  }

  @override
  int get hashCode => Object.hash(
    databasePath,
    playerFideId,
    revision,
    windowDays,
    timeControlCategory,
    preferredRatingTimeControl,
    unclassifiedTimeControlCategory,
    playerOutcome,
    playerColor,
    Object.hashAll(aliases),
  );
}

final playerStatsProvider = FutureProvider.autoDispose
    .family<PlayerStatsSnapshot, PlayerStatsRequest>((ref, request) async {
      final repository = ref.watch(playerStatsRepositoryProvider);
      final cancellationToken = OperationCancellationToken();
      ref.onDispose(cancellationToken.cancel);
      final snapshot = await repository.computePlayerStats(
        databasePath: request.databasePath,
        aliases: request.aliases,
        playerFideId: request.playerFideId,
        windowDays: request.windowDays,
        timeControlCategory: request.timeControlCategory,
        preferredRatingTimeControl: request.preferredRatingTimeControl,
        unclassifiedTimeControlCategory:
            request.unclassifiedTimeControlCategory,
        playerOutcome: request.playerOutcome,
        playerColor: request.playerColor,
        cancellationToken: cancellationToken,
      );
      cancellationToken.throwIfCanceled();

      // A completed source snapshot is small, while recomputing it re-scans a
      // large player database. Retain only successful requests briefly so
      // switching back to a source is instant; in-flight requests remain
      // auto-disposable and are canceled above.
      final keepAlive = ref.keepAlive();
      final expiry = Timer(const Duration(minutes: 5), keepAlive.close);
      ref.onDispose(expiry.cancel);
      return snapshot;
    });
