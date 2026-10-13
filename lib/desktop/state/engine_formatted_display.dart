import 'dart:async';

import 'package:flutter/foundation.dart';

import 'board_eval.dart';

/// One display-only reading. Its source FEN and SAN never become current-board
/// evaluation data; arrows, reports and saves continue using boardEvalProvider.
class FormattedEngineReading {
  const FormattedEngineReading(this.fen, this.state, this.sanLines);

  final String fen;
  final BoardEvalState state;
  final List<List<String>> sanLines;
}

/// Retain a complete formatted MultiPV reading until every replacement row is
/// ready. Only the newest target/request can publish; score-only updates reuse
/// SAN when their full move set still matches the displayed reading.
class EngineFormattedDisplay extends ChangeNotifier {
  EngineFormattedDisplay({required this.formatSan});

  final Future<List<String>> Function(Map<String, String>) formatSan;
  FormattedEngineReading? _snapshot;
  String? _target;
  BoardEvalState? _pending;
  String? _pendingKey;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  FormattedEngineReading? get snapshot => _snapshot;
  String? get fen => _snapshot?.fen;
  BoardEvalState? get reading => _snapshot?.state;

  String _key(String fen, BoardEvalState state) =>
      '$fen\u0000${state.pvs.map((pv) => pv.moves).join('\u0000')}';

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
    if (_target != target) {
      _invalidatePending();
      _target = target;
    }
    if (current.pvs.isNotEmpty) {
      final key = _key(target, current);
      final shown = _snapshot;
      if (shown != null && key == _key(shown.fen, shown.state)) {
        if (!identical(shown.state, current)) {
          _snapshot = FormattedEngineReading(target, current, shown.sanLines);
        }
        if (_pendingKey != null) _invalidatePending();
      } else if (_pendingKey == key) {
        // The captured moves are unchanged, so their latest score/depth can be
        // paired with the same worker output rather than restarting conversion.
        _pending = current;
      } else {
        // Coalesce to the latest moves without resetting the original window:
        // continuous engine info must not postpone conversion indefinitely.
        _generation++;
        _pendingKey = key;
        _pending = current;
        _timer ??= Timer(const Duration(milliseconds: 120), () {
          _timer = null;
          final source = _pending;
          final pendingKey = _pendingKey;
          final pendingTarget = _target;
          if (source == null || pendingKey == null || pendingTarget == null) {
            return;
          }
          unawaited(_format(pendingTarget, pendingKey, _generation, source));
        });
      }
    }
    // Never let an unformatted incoming score/depth get ahead of visible SAN.
    return _snapshot?.state ?? current.copyWith(pvs: const [], depth: 0);
  }

  bool isCurrent(String target, BoardEvalState current) =>
      _snapshot?.fen == target && identical(_snapshot?.state, current);

  Future<void> _format(
    String target,
    String key,
    int generation,
    BoardEvalState source,
  ) async {
    bool current() =>
        !_disposed &&
        generation == _generation &&
        target == _target &&
        key == _pendingKey;
    try {
      final labels = await Future.wait(
        source.pvs.map((pv) => formatSan({'fen': target, 'moves': pv.moves})),
      );
      if (!current()) return;
      final rawUci = RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$');
      if (labels.any((row) => row.isEmpty || row.any(rawUci.hasMatch))) {
        return;
      }
      final state = _pending!;
      _snapshot = FormattedEngineReading(
        target,
        state,
        List<List<String>>.unmodifiable(
          labels.map((row) => List<String>.unmodifiable(row)),
        ),
      );
      _pending = null;
      _pendingKey = null;
      notifyListeners();
    } catch (_) {
      // A failed row cannot replace the complete display with a partial set.
    } finally {
      if (current()) {
        _pending = null;
        _pendingKey = null;
      }
    }
  }

  void _invalidatePending() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _pendingKey = null;
  }

  void clear() {
    _invalidatePending();
    _target = null;
    _snapshot = null;
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
