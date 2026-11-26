import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/toby_enabled.dart';
import 'package:chessever/providers/engine_settings_provider.dart';

const _stockfishKey = 'desktop.analysis.stockfish.v1';
const _stockfishLinesKey = 'desktop.analysis.stockfishLines.v1';
const _defaultStockfishLineIndex = 2;
const _stockfishBarKey = 'desktop.analysis.stockfishBar.v1';
const _arrowSourceKey = 'desktop.analysis.arrows.v1';

enum BoardAnalysisArrows { stockfish, toby, off }

/// The "Board arrows" choices in settings, in order. Toby's is offered only
/// while Toby is on.
List<BoardAnalysisArrows> boardArrowSources({required bool tobyEnabled}) =>
    tobyEnabled
        ? BoardAnalysisArrows.values
        : const [BoardAnalysisArrows.stockfish, BoardAnalysisArrows.off];

String boardArrowSourceLabel(BoardAnalysisArrows source) => switch (source) {
  BoardAnalysisArrows.stockfish => 'Stockfish',
  BoardAnalysisArrows.toby => 'Toby',
  BoardAnalysisArrows.off => 'Off',
};

@immutable
class BoardAnalysisPreferences {
  const BoardAnalysisPreferences({
    this.paused = false,
    this.stockfishAnalysis = true,
    this.stockfishLineIndex = _defaultStockfishLineIndex,
    this.tobyAnalysis = true,
    this.tobyEnabled = true,
    this.stockfishBarChoice,
    this.arrowChoice,
  });

  final bool paused;
  final bool stockfishAnalysis;
  final int stockfishLineIndex;

  /// Toby Predicts in the engine pane. On the Board this is the account's
  /// Toby switch ([tobyEnabledProvider]); in a Play game it is the player's
  /// Toby Predicts help module.
  final bool tobyAnalysis;

  /// The account's Toby switch ([tobyEnabledProvider]). Off, nothing of
  /// Toby shows: no Toby bar, and Toby arrows fall back to Stockfish's.
  final bool tobyEnabled;
  final bool? stockfishBarChoice;
  final BoardAnalysisArrows? arrowChoice;

  bool stockfishBar(EngineSettings engine) =>
      stockfishBarChoice ?? engine.showEngineGauge;

  BoardAnalysisArrows arrows(EngineSettings engine) {
    final choice =
        arrowChoice ??
        (engine.showPvArrows
            ? BoardAnalysisArrows.stockfish
            : BoardAnalysisArrows.off);
    return choice == BoardAnalysisArrows.toby && !tobyEnabled
        ? BoardAnalysisArrows.stockfish
        : choice;
  }

  BoardAnalysisPreferences copyWith({
    bool? paused,
    bool? stockfishAnalysis,
    int? stockfishLineIndex,
    bool? tobyAnalysis,
    bool? tobyEnabled,
    bool? stockfishBarChoice,
    BoardAnalysisArrows? arrowChoice,
  }) => BoardAnalysisPreferences(
    paused: paused ?? this.paused,
    stockfishAnalysis: stockfishAnalysis ?? this.stockfishAnalysis,
    stockfishLineIndex: stockfishLineIndex ?? this.stockfishLineIndex,
    tobyAnalysis: tobyAnalysis ?? this.tobyAnalysis,
    tobyEnabled: tobyEnabled ?? this.tobyEnabled,
    stockfishBarChoice: stockfishBarChoice ?? this.stockfishBarChoice,
    arrowChoice: arrowChoice ?? this.arrowChoice,
  );
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
    // Toby Predicts on the Board is the account's Toby switch itself.
    ref.listen<bool>(tobyEnabledProvider, (_, on) {
      if (state.tobyEnabled == on && state.tobyAnalysis == on) return;
      state = state.copyWith(tobyAnalysis: on, tobyEnabled: on);
    });
    final toby = ref.read(tobyEnabledProvider);
    unawaited(_restore());
    return BoardAnalysisPreferences(tobyAnalysis: toby, tobyEnabled: toby);
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      final arrow = preferences.getString(_arrowSourceKey);
      final lineIndex =
          _edited.contains(_stockfishLinesKey)
              ? state.stockfishLineIndex
              : preferences.getInt(_stockfishLinesKey) ??
                  _defaultStockfishLineIndex;
      state = BoardAnalysisPreferences(
        paused: state.paused,
        stockfishLineIndex: _clampLineIndex(lineIndex),
        stockfishAnalysis:
            _edited.contains(_stockfishKey)
                ? state.stockfishAnalysis
                : preferences.getBool(_stockfishKey) ?? true,
        tobyAnalysis: state.tobyAnalysis,
        tobyEnabled: state.tobyEnabled,
        stockfishBarChoice:
            _edited.contains(_stockfishBarKey)
                ? state.stockfishBarChoice
                : preferences.getBool(_stockfishBarKey),
        arrowChoice:
            _edited.contains(_arrowSourceKey)
                ? state.arrowChoice
                : BoardAnalysisArrows.values.asNameMap()[arrow],
      );
    } catch (error) {
      debugPrint('Board analysis preferences could not be restored: $error');
    }
  }

  void setPaused(bool value) {
    state = state.copyWith(paused: value);
  }

  /// The Board's Toby switch: the account's, for every Toby surface.
  void setTobyAnalysis(bool value) {
    ref.read(tobyEnabledProvider.notifier).set(value);
    state = state.copyWith(tobyAnalysis: value, tobyEnabled: value);
  }

  void setStockfishAnalysis(bool value) {
    _edited.add(_stockfishKey);
    state = state.copyWith(stockfishAnalysis: value);
    _save((p) => p.setBool(_stockfishKey, value));
  }

  static int _clampLineIndex(int index) =>
      index.clamp(0, EngineSettings.principalVariationLabels.length - 1);

  void setStockfishLineIndex(int index) {
    final value = _clampLineIndex(index);
    _edited.add(_stockfishLinesKey);
    state = state.copyWith(stockfishLineIndex: value);
    _save((p) => p.setInt(_stockfishLinesKey, value));
  }

  void setStockfishBar(bool value) {
    _edited.add(_stockfishBarKey);
    state = state.copyWith(stockfishBarChoice: value);
    _save((p) => p.setBool(_stockfishBarKey, value));
  }

  void setArrows(BoardAnalysisArrows value) {
    _edited.add(_arrowSourceKey);
    state = state.copyWith(arrowChoice: value);
    _save((p) => p.setString(_arrowSourceKey, value.name));
  }

  void _save(Future<bool> Function(SharedPreferences) write) {
    _writes = _writes
        .then((_) async {
          await write(await SharedPreferences.getInstance());
        })
        .catchError((Object error) {
          debugPrint('Board analysis preferences could not be saved: $error');
        });
  }
}
