import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';

typedef SupabasePgnFetcher = Future<String?> Function(String gameId);
typedef GamebaseGameWithPgnFetcher =
    Future<GamebaseGameWithPgn?> Function(String gameId);

/// Resolves the best PGN for a desktop Board tab opened from a game id.
///
/// Desktop tabs can be created from Supabase tournament rows, Gamebase global
/// search rows, opening-explorer position rows, and player score-card rows.
/// Several of those rows only carry headers or no PGN at all, so the Board
/// pane needs the same remote fallback chain the mobile viewer uses before it
/// decides a game really has no notation.
Future<String?> resolveBoardTabPgn({
  required String gameId,
  String? initialPgn,
  required SupabasePgnFetcher fetchSupabasePgn,
  required GamebaseGameWithPgnFetcher fetchGamebaseGameWithPgn,
  bool requireMoves = true,
}) async {
  final normalizedGameId = gameId.trim();
  if (normalizedGameId.isEmpty) return _nonEmpty(initialPgn);

  final initial = _nonEmpty(initialPgn);
  if (initial != null) {
    if (!requireMoves || pgnHasMoves(initial)) return initial;
  }

  String? fallback = initial;

  try {
    final supabasePgn = _nonEmpty(await fetchSupabasePgn(normalizedGameId));
    if (supabasePgn != null) {
      if (!requireMoves || pgnHasMoves(supabasePgn)) return supabasePgn;
      fallback ??= supabasePgn;
    }
  } catch (_) {
    // A Gamebase UUID is not expected to exist in Supabase. Continue to the
    // Gamebase endpoint instead of surfacing a false empty-notation state.
  }

  try {
    final game = await fetchGamebaseGameWithPgn(normalizedGameId);
    if (game != null) {
      final candidates = <String?>[
        _nonEmpty(buildPgnFromGamebaseData(game.data)),
        _nonEmpty(game.pgn),
      ];

      for (final candidate in candidates) {
        if (candidate == null) continue;
        if (!requireMoves || pgnHasMoves(candidate)) return candidate;
        fallback ??= candidate;
      }
    }
  } catch (_) {
    // Keep the best PGN/header payload already found.
  }

  return fallback;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
