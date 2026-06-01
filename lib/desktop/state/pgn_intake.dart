import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Most recent PGN dropped or otherwise imported into the desktop app.
///
/// The shell pushes imports into here when a `.pgn` file is dropped on the
/// window. Panes that care (Board, Library) read this to load the game.
/// Holding only the latest one keeps the API minimal — multi-import flows
/// (whole `.pgn` collections) can append to a list later, but for the
/// drag-one-game-into-the-window case a single slot is enough.
class PgnImport {
  const PgnImport({required this.path, required this.pgn, this.gameId});

  final String path;
  final String pgn;

  /// Optional live/tournament game id for imports that came from a known
  /// game row. File drops and clipboard imports leave this null so the Board
  /// pane treats them as detached PGNs, never as live-broadcast updates.
  final String? gameId;
}

class PgnIntakeNotifier extends StateNotifier<PgnImport?> {
  PgnIntakeNotifier() : super(null);

  void addImport({required String path, required String pgn, String? gameId}) {
    state = PgnImport(path: path, pgn: pgn, gameId: gameId);
  }

  void clear() {
    state = null;
  }
}

final pgnIntakeProvider = StateNotifierProvider<PgnIntakeNotifier, PgnImport?>((
  ref,
) {
  return PgnIntakeNotifier();
});
