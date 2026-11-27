import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';

ChessGameNavigatorState? _cutBoundary(
  ChessGame game,
  ChessMovePointer pointer,
) {
  if (pointer.length.isEven || pointer.any((index) => index < 0)) return null;
  if (pointer.length == 1 && pointer.first == 0) return null;
  final state = ChessGameNavigatorState(game: game, movePointer: pointer);
  return state.currentMove == null ? null : state;
}

bool canCutBoardPreviousMoves(ChessGame game, ChessMovePointer pointer) =>
    _cutBoundary(game, pointer) != null;

/// Retain the selected move and its line's continuation, not any parent
/// continuation. The new root is the position before the selected move.
ChessGame? cutBoardPreviousMoves(ChessGame game, ChessMovePointer pointer) {
  final boundary = _cutBoundary(game, pointer);
  if (boundary == null) return null;
  final removed = pointer.last;
  final path = boundary.fullMovePath;
  final predecessor = path.length > 1 ? path[path.length - 2] : null;
  final rootFen = predecessor?.fen ?? game.startingFen;
  final line = boundary.currentLine!;
  final mainline = line.sublist(removed);
  final first = mainline.first;
  // Keep alternatives from this line's removed predecessor when they start
  // at the new root. A promoted variation does not import parent siblings.
  final rootVariations = [
    for (final variation
        in (removed > 0 ? line[removed - 1].variations : null) ??
            const <ChessLine>[])
      if (variation.isNotEmpty &&
          variation.first.turn == first.turn &&
          variation.first.num == first.num)
        variation,
  ];
  if (rootVariations.isNotEmpty) {
    mainline[0] = first.copyWith(
      variations: [...rootVariations, ...?first.variations],
      overrideVariations: true,
    );
  }
  final ending = pointer.length == 1 ? game.gameEndingPlyIndex : null;
  final retainsResult = ending != null && ending >= removed && !game.isLiveGame;
  final metadata =
      Map<String, dynamic>.of(game.metadata)
        ..['FEN'] = rootFen
        ..['SetUp'] = '1'
        ..['Result'] = retainsResult ? game.metadata['Result'] : '*'
        ..[ChessGame.metadataIsLiveKey] = false
        ..[ChessGame.metadataAllowMainlineExtensionKey] =
            !retainsResult || game.allowMainlineExtension
        ..remove(ChessGame.metadataGameEndingPlyIndexKey);
  if (retainsResult) {
    metadata[ChessGame.metadataGameEndingPlyIndexKey] = ending - removed;
  }
  return game.copyWith(
    startingFen: rootFen,
    metadata: metadata,
    mainline: List<ChessMove>.unmodifiable(mainline),
    rootComments: predecessor == null ? game.rootComments : const [],
    overrideDetachedRootAnalysis: true,
  );
}

/// Mainline-only overlays use zero-based move indices. A promoted sideline
/// already carries its own annotations on its move nodes.
Map<int, List<int>> rebaseCutPreviousUserNags(
  Map<int, List<int>> userNags,
  ChessMovePointer pointer,
  int retainedCount,
) {
  if (pointer.length != 1) return const {};
  final removed = pointer.first;
  return {
    for (final entry in userNags.entries)
      if (entry.key >= removed && entry.key < removed + retainedCount)
        entry.key - removed: entry.value,
  };
}
