import 'board_eval.dart';

/// A panel-local display cache, never an evaluation of the current board.
/// Saves, arrows, reports and keyboard actions must read boardEvalProvider.
class EngineDisplay {
  BoardEvalState? _reading;
  String? fen;
  BoardEvalState? get reading => _reading;

  BoardEvalState update(
    String target,
    BoardEvalState current, {
    required bool enabled,
  }) {
    if (!enabled ||
        current.statusText != null ||
        (!current.isEvaluating && current.pvs.isEmpty)) {
      clear();
      return current;
    }
    if (current.pvs.isNotEmpty) {
      _reading = current;
      fen = target;
    }
    return _reading ?? current;
  }

  bool isCurrent(String target, BoardEvalState current) =>
      fen == target && current.pvs.isNotEmpty && identical(_reading, current);

  void clear() {
    _reading = null;
    fen = null;
  }
}
