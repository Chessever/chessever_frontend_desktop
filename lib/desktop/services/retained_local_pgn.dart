import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as path;

import '../state/active_board_game.dart';
import '../state/tournament_games.dart';
import 'local_chess_database_repository.dart';
import 'local_chess_pgn_fingerprint.dart';
import 'local_library_game_updater.dart';
import 'local_pgn_source.dart';
import 'local_pgn_source_recovery.dart';

final retainedLocalPgnHydratorProvider =
    Provider<Future<TournamentGameSummary> Function(TournamentGameSummary)>(
      (ref) => (game) => hydrateRetainedLocalPgn(
        game,
        recovery: LocalPgnSourceRecovery(
          // Re-indexing goes through the repository, so the rescan shares the
          // single local-cache writer queue (AGENTS.md §3) and is single-flight
          // per source path.
          reindexSource: (sourcePath) => ref
              .read(localChessDatabaseRepositoryProvider)
              .reconcileLocalPgnCacheFromFile(databasePath: sourcePath),
        ),
      ),
    );

/// Activation is a read refresh, not permission to overwrite an old revision.
/// Validate physical identity but acquire the current annotation revision. The
/// updater still requires the exact revision captured by this read.
///
/// The stored coordinates are the primary answer: when they verify against the
/// file, nothing else runs. When they cannot be verified (the source changed
/// after it was indexed, or the row was never fully captured), [recovery]
/// re-indexes that source and re-resolves the *same game by identity*, so the
/// open succeeds instead of dead-ending on an unverifiable ordinal. Without a
/// [recovery] the previous fail-safe behavior is preserved for direct callers.
Future<TournamentGameSummary> hydrateRetainedLocalPgn(
  TournamentGameSummary game, {
  LocalPgnSourceRecovery? recovery,
}) async {
  final source = game.localPgnSource;
  if (source == null) return game;
  if (source.pgnFingerprint.isEmpty || source.sourceFileGameCount <= 0) {
    if (recovery == null) {
      throw StateError('Refresh the database before opening this game.');
    }
    return _recoverLocalPgnThenHydrate(game, source, recovery);
  }
  try {
    // Off the UI isolate: this runs on every open of a database game, and the
    // whole-file boundary scan behind it is seconds long for a large PGN.
    final pgn = await readLocalPgnRecordInBackground(
      path: source.sourcePath,
      indexInFile: source.sourceIndex,
      expectedFileGameCount: source.sourceFileGameCount,
      expectedPgnFingerprint: source.pgnFingerprint,
    );
    return _hydratedLocalPgn(
      game,
      source,
      pgn,
      indexInFile: source.sourceIndex,
      fileGameCount: source.sourceFileGameCount,
    );
  } on StateError {
    if (recovery == null) rethrow;
    return _recoverLocalPgnThenHydrate(game, source, recovery);
  }
}

TournamentGameSummary _hydratedLocalPgn(
  TournamentGameSummary game,
  TournamentGameLocalPgnSource source,
  String pgn, {
  required int indexInFile,
  required int fileGameCount,
}) => game.copyWith(
  pgn: pgn,
  localPgnSource: TournamentGameLocalPgnSource(
    sourcePath: source.sourcePath,
    sourceIndex: indexInFile,
    sourceFileGameCount: fileGameCount,
    pgnFingerprint: localChessPgnFingerprint(pgn),
    recordRevision: localPgnRecordRevision(pgn),
    title: source.title,
  ),
);

/// The stored coordinates could not be verified: re-index the changed source,
/// open the same game by identity, and verify the recovered record with the
/// ordinary reader before handing it to the Board.
///
/// Two bounded attempts: a save or append that lands between the recovery read
/// and the verifying read is retried once, then reported as a file that is
/// being written — never as a silent fallback to a stale PGN.
Future<TournamentGameSummary> _recoverLocalPgnThenHydrate(
  TournamentGameSummary game,
  TournamentGameLocalPgnSource source,
  LocalPgnSourceRecovery recovery,
) async {
  final identity = LocalPgnRecordIdentity.forSummary(game);
  Object? lastReadError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final resolution = await recovery.recover(
        sourcePath: source.sourcePath,
        identity: identity,
      );
      final pgn = await readLocalPgnRecordInBackground(
        path: source.sourcePath,
        indexInFile: resolution.indexInFile,
        expectedFileGameCount: resolution.fileGameCount,
        expectedPgnFingerprint: resolution.mainlineFingerprint,
      );
      return _hydratedLocalPgn(
        game,
        source,
        pgn,
        indexInFile: resolution.indexInFile,
        fileGameCount: resolution.fileGameCount,
      );
    } on LocalPgnGameUnavailableException {
      rethrow; // Already human-readable and actionable.
    } on StateError catch (error) {
      // The file changed again between the recovery read and this read.
      lastReadError = error;
    }
  }
  throw LocalPgnGameUnavailableException(
    sourcePath: source.sourcePath,
    failure: LocalPgnRecoveryFailure.sourceChanging,
    title: source.title,
    detail: lastReadError?.toString() ?? '',
  );
}

/// Publish only retained navigation summaries, never a mounted Board's PGN
/// seed, private tree, session or save baseline. In particular another dirty
/// tab must keep its old revision so its next save detects the conflict.
/// The prior revision is a CAS: an older completion cannot regress a newer row.
void publishRetainedLocalPgnCommit(
  ProviderContainer container, {
  required LocalLibraryGameUpdateTarget previous,
  required LocalLibraryGameUpdateOutcome outcome,
}) {
  final target = outcome.updateTarget;
  List<TournamentGameSummary> refresh(List<TournamentGameSummary> rows) {
    var changed = false;
    final next = rows
        .map((row) {
          final source = row.localPgnSource;
          if (source == null ||
              !path.equals(source.sourcePath, previous.sourcePath) ||
              source.sourceIndex != previous.indexInFile ||
              source.sourceFileGameCount != previous.fileGameCount ||
              source.pgnFingerprint != previous.pgnFingerprint ||
              source.recordRevision != previous.recordRevision) {
            return row;
          }
          changed = true;
          return row.copyWith(
            pgn: outcome.committedPgn,
            localPgnSource: TournamentGameLocalPgnSource(
              sourcePath: target.sourcePath,
              sourceIndex: target.indexInFile,
              sourceFileGameCount: target.fileGameCount,
              pgnFingerprint: target.pgnFingerprint,
              recordRevision: target.recordRevision,
              title: source.title,
            ),
          );
        })
        .toList(growable: false);
    return changed ? next : rows;
  }

  container.read(boardTabGameArgsByTabIdProvider.notifier).update((byTab) {
    var changed = false;
    final next = byTab.map((id, args) {
      final database = refresh(args.databaseGames);
      final route = refresh(args.routeGames);
      final event = refresh(args.eventGames);
      if (identical(database, args.databaseGames) &&
          identical(route, args.routeGames) &&
          identical(event, args.eventGames)) {
        return MapEntry(id, args);
      }
      changed = true;
      return MapEntry(
        id,
        args.copyWith(
          retainedSeedIdentity: args.retainedSeedIdentity ?? args,
          databaseGames: database,
          routeGames: route,
          eventGames: event,
        ),
      );
    });
    return changed ? next : byTab;
  });
}
