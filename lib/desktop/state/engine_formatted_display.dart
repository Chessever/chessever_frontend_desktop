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
/// ready. Score-only updates reuse SAN when their full move set still matches
/// the displayed or converting reading.
///
/// On one target, conversion is latest-wins coalescing: a batch already
/// converting is allowed to publish, and only the newest move set that arrived
/// meanwhile is converted next. Restarting on every move change starved the
/// display while the engine kept refining its lines. A change of target (or
/// [clear]) still discards every older result.
class EngineFormattedDisplay extends ChangeNotifier {
  EngineFormattedDisplay({required this.formatSan});

  final Future<List<String>> Function(Map<String, String>) formatSan;
  FormattedEngineReading? _snapshot;
  String? _target;
  // Newest move set waiting for conversion, with its latest score/depth.
  BoardEvalState? _pending;
  String? _pendingKey;
  // The batch being converted, with its latest score/depth.
  BoardEvalState? _converting;
  String? _convertingKey;
  int? _activeConversion;
  int _conversionSerial = 0;
  // Bumped by a target change, clear or dispose: older work never publishes.
  int _epoch = 0;
  Timer? _timer;
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
        // The visible set is the newest again; older conversions must not
        // replace it.
        _dropPending();
        _abandonConversion();
      } else if (key == _convertingKey) {
        // Same moves as the batch in progress: it publishes with this score.
        _converting = current;
        _dropPending();
      } else if (key == _pendingKey) {
        // The captured moves are unchanged, so their latest score/depth can be
        // paired with the same worker output rather than restarting conversion.
        _pending = current;
      } else {
        // Coalesce to the latest moves without resetting the original window:
        // continuous engine info must not postpone conversion indefinitely.
        _pendingKey = key;
        _pending = current;
        if (_activeConversion == null) {
          _timer ??= Timer(const Duration(milliseconds: 120), () {
            _timer = null;
            _startPending();
          });
        }
      }
    }
    // Never let an unformatted incoming score/depth get ahead of visible SAN.
    return _snapshot?.state ?? current.copyWith(pvs: const [], depth: 0);
  }

  bool isCurrent(String target, BoardEvalState current) =>
      _snapshot?.fen == target && identical(_snapshot?.state, current);

  void _startPending() {
    final target = _target;
    final key = _pendingKey;
    final source = _pending;
    if (_disposed ||
        _activeConversion != null ||
        target == null ||
        key == null ||
        source == null) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _pendingKey = null;
    _converting = source;
    _convertingKey = key;
    final serial = ++_conversionSerial;
    _activeConversion = serial;
    unawaited(_format(target, serial, _epoch, source));
  }

  Future<void> _format(
    String target,
    int serial,
    int epoch,
    BoardEvalState source,
  ) async {
    bool current() =>
        !_disposed &&
        epoch == _epoch &&
        target == _target &&
        serial == _activeConversion;
    try {
      final labels = await Future.wait(
        source.pvs.map((pv) => formatSan({'fen': target, 'moves': pv.moves})),
      );
      if (!current()) return;
      final rawUci = RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$');
      if (labels.any((row) => row.isEmpty || row.any(rawUci.hasMatch))) {
        return;
      }
      _snapshot = FormattedEngineReading(
        target,
        _converting!,
        List<List<String>>.unmodifiable(
          labels.map((row) => List<String>.unmodifiable(row)),
        ),
      );
      notifyListeners();
    } catch (_) {
      // A failed row cannot replace the complete display with a partial set.
    } finally {
      if (current()) {
        _abandonConversion();
        // Latest wins: whatever queued during this batch converts next.
        _startPending();
      }
    }
  }

  void _dropPending() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _pendingKey = null;
  }

  void _abandonConversion() {
    _activeConversion = null;
    _converting = null;
    _convertingKey = null;
  }

  void _invalidatePending() {
    _epoch++;
    _dropPending();
    _abandonConversion();
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
