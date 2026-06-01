import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/pgn_intake.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';

/// Resolves a tournament (group_broadcast) into a PGN and pushes it through
/// `pgnIntakeProvider` so the Board pane picks it up.
///
/// The chain on Supabase is `group_broadcast → tours → games`. We pick the
/// highest-rated tour (already ordered by `avg_elo` in the repository) and
/// then the first game's `pgn` blob. Any link in the chain failing surfaces
/// as a debug log; the Tournaments pane stays interactive.
class TournamentPgnLoader {
  TournamentPgnLoader(this.ref);
  final WidgetRef ref;

  Future<bool> loadFirstGameForTournament({
    required String groupBroadcastId,
    required String tournamentTitle,
  }) async {
    try {
      final tours = await ref
          .read(tourRepositoryProvider)
          .getTourByGroupId(groupBroadcastId);
      if (tours.isEmpty) return false;

      final tour = tours.first;
      final games = await ref
          .read(gameRepositoryProvider)
          .getGamesByTourId(tour.id);
      if (games.isEmpty) return false;

      // Cache the games list so the Board pane can show a switcher.
      ref
          .read(tournamentGamesProvider.notifier)
          .setLoaded(
            tournamentTitle: tournamentTitle,
            games: games
                .map(TournamentGameSummary.fromGame)
                .toList(growable: false),
          );

      // Find a game that already has PGN (live broadcasts may have games
      // with empty PGN until the first move is played).
      final withPgn = games.firstWhere(
        (g) => g.pgn != null && g.pgn!.trim().isNotEmpty,
        orElse: () => games.first,
      );

      return await loadGameById(
        gameId: withPgn.id,
        cachedPgn: withPgn.pgn,
        path: '$tournamentTitle / ${withPgn.name ?? withPgn.id}',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ TournamentPgnLoader failed: $e');
      }
      return false;
    }
  }

  /// Loads a specific game by id (used when the user picks one from the
  /// tournament-games sidebar). Marks the game active so the BoardPane's
  /// live stream subscription kicks in, and seeds an initial PGN through
  /// `pgnIntakeProvider` if one is available right now. Live games may
  /// have no PGN yet — in that case we still mark the game active and
  /// open the tab; the Realtime stream populates moves as they happen.
  Future<bool> loadGameById({
    required String gameId,
    String? cachedPgn,
    required String path,
  }) async {
    try {
      ref.read(tournamentGamesProvider.notifier).markActive(gameId);
      var pgn = cachedPgn;
      if (pgn == null || pgn.trim().isEmpty) {
        pgn = await ref.read(gameRepositoryProvider).getGamePgn(gameId);
      }
      if (pgn != null && pgn.trim().isNotEmpty) {
        ref
            .read(pgnIntakeProvider.notifier)
            .addImport(path: path, pgn: pgn, gameId: gameId);
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ TournamentPgnLoader.loadGameById failed: $e');
      }
      return false;
    }
  }

  /// Pure fetch — no provider side-effects. Used by the per-game tab
  /// opener when it just wants the PGN string to seed
  /// `BoardTabGameArgs.pgn`.
  Future<String?> fetchPgnOnly(String gameId) async {
    try {
      final pgn = await ref.read(gameRepositoryProvider).getGamePgn(gameId);
      if (pgn == null || pgn.trim().isEmpty) return null;
      return pgn;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ TournamentPgnLoader.fetchPgnOnly failed: $e');
      }
      return null;
    }
  }
}
