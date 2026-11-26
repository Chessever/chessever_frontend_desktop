import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/providers/engine_settings_provider.dart';

const _stockfishKey = 'desktop.analysis.stockfish.v1';
const _stockfishLinesKey = 'desktop.analysis.stockfishLines.v1';
const _defaultStockfishLineIndex = 2;
const _tobyKey = 'desktop.analysis.toby.v1';
const _stockfishBarKey = 'desktop.analysis.stockfishBar.v1';
const _arrowSourceKey = 'desktop.analysis.arrows.v1';

enum BoardAnalysisArrows { stockfish, toby, off }

@immutable
class BoardAnalysisPreferences {
  const BoardAnalysisPreferences({
    this.paused = false,
    this.stockfishAnalysis = true,
    this.stockfishLineIndex = _defaultStockfishLineIndex,
    this.tobyAnalysis = true,
    this.stockfishBarChoice,
    this.arrowChoice,
  });

  final bool paused;
  final bool stockfishAnalysis;
  final int stockfishLineIndex;
  final bool tobyAnalysis;
  final bool? stockfishBarChoice;
  final BoardAnalysisArrows? arrowChoice;

  bool stockfishBar(EngineSettings engine) =>
      stockfishBarChoice ?? engine.showEngineGauge;

  BoardAnalysisArrows arrows(EngineSettings engine) =>
      arrowChoice ??
      (engine.showPvArrows ? BoardAnalysisArrows.stockfish : BoardAnalysisArrows.off);
}

final boardAnalysisPreferencesProvider =
    NotifierProvider<BoardAnalysisSettings, BoardAnalysisPreferences>(
      BoardAnalysisSettings.new,
    );

/// UI preferences shared by the Board surfaces of this app, not by the
/// mobile shell. Play games override this provider with their own help
/// modules (`PlayAnalysisSettings`). Pause is temporary; the individual choices are saved.
class BoardAnalysisSettings extends Notifier<BoardAnalysisPreferences> {
  final Set<String> _edited = {};
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();

  @override
  BoardAnalysisPreferences build() {
    ref.onDispose(() => _disposed = true);
    unawaited(_restore());
    return const BoardAnalysisPreferences();
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      final arrow = preferences.getString(_arrowSourceKey);
      final lineIndex = _edited.contains(_stockfishLinesKey)
          ? state.stockfishLineIndex
          : preferences.getInt(_stockfishLinesKey) ?? _defaultStockfishLineIndex;
      state = BoardAnalysisPreferences(
        paused: state.paused,
        stockfishLineIndex: _clampLineIndex(lineIndex),
        stockfishAnalysis: _edited.contains(_stockfishKey)
            ? state.stockfishAnalysis
            : preferences.getBool(_stockfishKey) ?? true,
        tobyAnalysis: _edited.contains(_tobyKey)
            ? state.tobyAnalysis
            : preferences.getBool(_tobyKey) ?? true,
        stockfishBarChoice: _edited.contains(_stockfishBarKey)
            ? state.stockfishBarChoice
            : preferences.getBool(_stockfishBarKey),
        arrowChoice: _edited.contains(_arrowSourceKey)
            ? state.arrowChoice
            : BoardAnalysisArrows.values.asNameMap()[arrow],
      );
    } catch (error) {
      debugPrint('Board analysis preferences could not be restored: $error');
    }
  }

  void setPaused(bool value) {
    state = BoardAnalysisPreferences(
      paused: value,
      stockfishLineIndex: state.stockfishLineIndex,
      stockfishAnalysis: state.stockfishAnalysis,
      tobyAnalysis: state.tobyAnalysis,
      stockfishBarChoice: state.stockfishBarChoice,
      arrowChoice: state.arrowChoice,
    );
  }

  void setTobyAnalysis(bool value) {
    _edited.add(_tobyKey);
    state = BoardAnalysisPreferences(
      paused: state.paused,
      stockfishLineIndex: state.stockfishLineIndex,
      stockfishAnalysis: state.stockfishAnalysis,
      tobyAnalysis: value,
      stockfishBarChoice: state.stockfishBarChoice,
      arrowChoice: state.arrowChoice,
    );
    _save((p) => p.setBool(_tobyKey, value));
  }

  void setStockfishAnalysis(bool value) {
    _edited.add(_stockfishKey);
    state = BoardAnalysisPreferences(
      paused: state.paused,
      stockfishLineIndex: state.stockfishLineIndex,
      stockfishAnalysis: value,
      tobyAnalysis: state.tobyAnalysis,
      stockfishBarChoice: state.stockfishBarChoice,
      arrowChoice: state.arrowChoice,
    );
    _save((p) => p.setBool(_stockfishKey, value));
  }

  static int _clampLineIndex(int index) =>
      index.clamp(0, EngineSettings.principalVariationLabels.length - 1);

  void setStockfishLineIndex(int index) {
    final value = _clampLineIndex(index);
    _edited.add(_stockfishLinesKey);
    state = BoardAnalysisPreferences(
      paused: state.paused,
      stockfishAnalysis: state.stockfishAnalysis,
      stockfishLineIndex: value,
      tobyAnalysis: state.tobyAnalysis,
      stockfishBarChoice: state.stockfishBarChoice,
      arrowChoice: state.arrowChoice,
    );
    _save((p) => p.setInt(_stockfishLinesKey, value));
  }

  void setStockfishBar(bool value) {
    _edited.add(_stockfishBarKey);
    state = BoardAnalysisPreferences(
      paused: state.paused,
      stockfishLineIndex: state.stockfishLineIndex,
      stockfishAnalysis: state.stockfishAnalysis,
      tobyAnalysis: state.tobyAnalysis,
      stockfishBarChoice: value,
      arrowChoice: state.arrowChoice,
    );
    _save((p) => p.setBool(_stockfishBarKey, value));
  }

  void setArrows(BoardAnalysisArrows value) {
    _edited.add(_arrowSourceKey);
    state = BoardAnalysisPreferences(
      paused: state.paused,
      stockfishLineIndex: state.stockfishLineIndex,
      stockfishAnalysis: state.stockfishAnalysis,
      tobyAnalysis: state.tobyAnalysis,
      stockfishBarChoice: state.stockfishBarChoice,
      arrowChoice: value,
    );
    _save((p) => p.setString(_arrowSourceKey, value.name));
  }

  void _save(Future<bool> Function(SharedPreferences) write) {
    _writes = _writes.then((_) async {
      await write(await SharedPreferences.getInstance());
    }).catchError((Object error) {
      debugPrint('Board analysis preferences could not be saved: $error');
    });
  }
}
