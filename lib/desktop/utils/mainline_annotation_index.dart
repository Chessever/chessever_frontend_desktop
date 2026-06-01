import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';

/// Returns the zero-based mainline annotation key for [pointer].
///
/// Lichess annotation payloads and notation tokens are keyed by the mainline
/// half-move index: `0` is the first move, `1` is the reply, and so on.
/// Variation pointers deliberately return null because those annotations only
/// describe the original mainline.
int? mainlineAnnotationIndexForPointer(ChessMovePointer pointer) {
  if (pointer.length != 1) return null;
  final index = pointer.first;
  return index >= 0 ? index : null;
}
