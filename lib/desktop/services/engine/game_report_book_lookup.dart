import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';

/// Opening-tree lookup backed by the game database.
///
/// Mirrors mobile's `_gamebaseBookLookup`: the two apps must agree on which
/// moves are theory, so both ask the gamebase the same question through the
/// same aggregates endpoint.
///
/// Returns null when the gamebase is not configured for this build, which keeps
/// book detection off rather than spending a failed request per opening move on
/// every report.
///
/// Takes the repository rather than a `Ref` so the desktop panel (which holds a
/// `WidgetRef`) and a test (which holds neither) can both reach it.
GameReportBookLookup? gamebaseBookLookup(GamebaseRepository repository) {
  if (!repository.isConfigured) return null;
  return (fen, uci, path) async {
    // Same request the board's opening-explorer panel makes: handing over the
    // move line is what lets the backend answer past its indexed opening
    // window, where a fen-only query returns an empty tree.
    final response = await repository.getMoveAggregates(fen: fen, moves: path);
    for (final aggregate in response.data.moves) {
      if (gamebaseAggregateMatchesMove(aggregate.uci, uci)) {
        return aggregate.total;
      }
    }
    // The position is known but this continuation is not in it — a real answer
    // of "no games", distinct from a failed lookup.
    return 0;
  };
}

/// Whether a gamebase aggregate row and a board move are the same move.
///
/// They disagree on castling: dartchess gives the board `e1h1` while the
/// backend answers `e1g1`. Compared raw, every castle read as a move the
/// database had never seen — which ends book detection at the first time either
/// side castled.
///
/// Pure helper so a unit test can hold the two spellings together.
bool gamebaseAggregateMatchesMove(String aggregateUci, String moveUci) =>
    aggregateUci == moveUci ||
    GamebaseRepository.alternateCastlingUci(moveUci) == aggregateUci;
