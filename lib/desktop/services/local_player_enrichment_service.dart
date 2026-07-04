import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_diagnostics.dart';
import 'package:chessever/repository/supabase/chess_player/chess_player_repository.dart';

/// Bumped whenever an enrichment pass writes new player tags, so open views
/// re-query and pick up the added titles/federations.
final localPlayerEnrichmentEpochProvider = StateProvider<int>((ref) => 0);

final localPlayerEnrichmentServiceProvider =
    Provider<LocalPlayerEnrichmentService>(LocalPlayerEnrichmentService.new);

/// Backfills missing player titles and federations for a local database from
/// the Supabase `chess_players` FIDE table, keyed strictly by FIDE ID.
///
/// Best-effort: failures (offline, Supabase hiccup) leave the database
/// unmarked so the next open retries; nothing in the import flow blocks on
/// this.
class LocalPlayerEnrichmentService {
  LocalPlayerEnrichmentService(this._ref);

  final Ref _ref;
  final Set<String> _inFlight = <String>{};

  Future<void> ensureDatabaseEnriched(String databasePath) async {
    final path = databasePath.trim();
    if (path.isEmpty || !_inFlight.add(path)) return;
    try {
      final repository = _ref.read(localChessDatabaseRepositoryProvider);
      final players = _ref.read(chessPlayerRepositoryProvider);
      final updated = await repository.enrichLocalDatabasePlayers(
        databasePath: path,
        resolve: (fideIds) async {
          final resolved = await players.getPlayersByFideIds(fideIds);
          return <int, LocalPlayerEnrichment>{
            for (final entry in resolved.entries)
              entry.key: LocalPlayerEnrichment(
                title: entry.value.title,
                federation: entry.value.country,
              ),
          };
        },
      );
      if (updated > 0) {
        _ref.read(localPlayerEnrichmentEpochProvider.notifier).state++;
        localChessLog.info(
          'Backfilled player titles/federations',
          context: <String, Object?>{'path': path, 'games': updated},
        );
      }
    } catch (error) {
      localChessLog.warning(
        'Player enrichment pass failed; will retry on next open',
        context: <String, Object?>{'path': path, 'error': '$error'},
      );
    } finally {
      _inFlight.remove(path);
    }
  }
}
