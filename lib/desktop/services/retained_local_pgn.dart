import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as path;

import '../state/active_board_game.dart';
import '../state/tournament_games.dart';
import 'local_chess_pgn_fingerprint.dart';
import 'local_library_game_updater.dart';
import 'local_pgn_source.dart';

final retainedLocalPgnHydratorProvider =
    Provider<Future<TournamentGameSummary> Function(TournamentGameSummary)>(
      (ref) => hydrateRetainedLocalPgn,
    );

/// Activation is a read refresh, not permission to overwrite an old revision.
/// Validate physical identity but acquire the current annotation revision. The
/// updater still requires the exact revision captured by this read.
Future<TournamentGameSummary> hydrateRetainedLocalPgn(
  TournamentGameSummary game,
) async {
  final source = game.localPgnSource;
  if (source == null) return game;
  if (source.pgnFingerprint.isEmpty || source.sourceFileGameCount <= 0) {
    throw StateError('Refresh the database before opening this game.');
  }
  // Off the UI isolate: this runs on every open of a database game, and the
  // whole-file boundary scan behind it is seconds long for a large PGN.
  final pgn = await readLocalPgnRecordInBackground(
    path: source.sourcePath,
    indexInFile: source.sourceIndex,
    expectedFileGameCount: source.sourceFileGameCount,
    expectedPgnFingerprint: source.pgnFingerprint,
  );
  return game.copyWith(
    pgn: pgn,
    localPgnSource: TournamentGameLocalPgnSource(
      sourcePath: source.sourcePath,
      sourceIndex: source.sourceIndex,
      sourceFileGameCount: source.sourceFileGameCount,
      pgnFingerprint: localChessPgnFingerprint(pgn),
      recordRevision: localPgnRecordRevision(pgn),
      title: source.title,
    ),
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
