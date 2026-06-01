import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// In-memory buffer of PGN games staged for import into a library folder.
///
/// The mobile app pushes a full-screen `PgnImportPreviewScreen` over the
/// route stack to mediate "user dropped/pasted/picked a multi-game PGN ->
/// pick a folder -> save". On desktop we don't push routes for primary
/// navigation, so the equivalent UI lives inline inside the Library pane.
///
/// The notifier holds the most recent staging batch. `accept` replaces it
/// (the user only ever sees one preview at a time); `clear` discards it
/// once the games have been saved or the user backs out.
class LibraryImportBuffer {
  const LibraryImportBuffer({
    required this.games,
    required this.sourceLabel,
    this.suggestedFolderId,
  });

  final List<ChessGame> games;
  final String sourceLabel;

  /// Folder to pre-select in the save sheet (e.g. when the user invoked
  /// "Import" from inside a folder context).
  final String? suggestedFolderId;
}

class LibraryImportBufferNotifier extends StateNotifier<LibraryImportBuffer?> {
  LibraryImportBufferNotifier() : super(null);

  void accept({
    required List<ChessGame> games,
    required String sourceLabel,
    String? suggestedFolderId,
  }) {
    if (games.isEmpty) return;
    state = LibraryImportBuffer(
      games: games,
      sourceLabel: sourceLabel,
      suggestedFolderId: suggestedFolderId,
    );
  }

  void clear() => state = null;
}

final libraryImportBufferProvider =
    StateNotifierProvider<LibraryImportBufferNotifier, LibraryImportBuffer?>(
  (_) => LibraryImportBufferNotifier(),
);
