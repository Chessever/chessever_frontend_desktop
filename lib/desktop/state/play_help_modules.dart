import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/board_analysis_preferences.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/play_session.dart';

const _storageKey = 'desktop.play.helpModules.v1';

/// Where the arrows on the play board come from. One source at a time, so
/// the board never mixes Stockfish's lines with Toby's guesses.
enum PlayHelpArrows { off, stockfish, toby }

/// The help a player chose for games against a bot, one module at a time.
/// Everything is off by default: a game is played as in competition until
/// the player turns something on, on the setup screen or during a game.
@immutable
class PlayHelpModules {
  const PlayHelpModules({
    this.engineLines = false,
    this.evalBar = false,
    this.tobyPredictions = false,
    this.tobyBar = false,
    this.moveMarks = false,
    this.explorer = false,
    this.arrowEvals = false,
    this.arrows = PlayHelpArrows.off,
  });

  /// Stockfish's lines in the rail.
  final bool engineLines;

  /// Stockfish's eval bar left of the board.
  final bool evalBar;

  /// Toby Predicts' candidate moves in the rail.
  final bool tobyPredictions;

  /// Toby's win/draw/loss bar right of the board.
  final bool tobyBar;

  /// The game report's mark (book, !!, ?? …) on each move as it is played.
  final bool moveMarks;

  /// The opening explorer in the rail.
  final bool explorer;

  /// The engine's eval on the player's own legal right-drawn arrows.
  final bool arrowEvals;

  /// Arrows on the board: none, Stockfish's best lines, or Toby's guesses.
  final PlayHelpArrows arrows;

  /// Whether the game shows the analysis rail instead of the plain move
  /// list: something in it was chosen, or Toby's arrows need its reading.
  bool get showsRail =>
      engineLines ||
      tobyPredictions ||
      explorer ||
      arrows == PlayHelpArrows.toby;

  /// Whether anything needs Stockfish searching the position on the board.
  bool get needsStockfish =>
      engineLines ||
      evalBar ||
      arrowEvals ||
      arrows == PlayHelpArrows.stockfish;

  bool get anyOn => this != const PlayHelpModules();

  PlayHelpModules copyWith({
    bool? engineLines,
    bool? evalBar,
    bool? tobyPredictions,
    bool? tobyBar,
    bool? moveMarks,
    bool? explorer,
    bool? arrowEvals,
    PlayHelpArrows? arrows,
  }) => PlayHelpModules(
    engineLines: engineLines ?? this.engineLines,
    evalBar: evalBar ?? this.evalBar,
    tobyPredictions: tobyPredictions ?? this.tobyPredictions,
    tobyBar: tobyBar ?? this.tobyBar,
    moveMarks: moveMarks ?? this.moveMarks,
    explorer: explorer ?? this.explorer,
    arrowEvals: arrowEvals ?? this.arrowEvals,
    arrows: arrows ?? this.arrows,
  );

  Map<String, Object> toJson() => {
    'engineLines': engineLines,
    'evalBar': evalBar,
    'tobyPredictions': tobyPredictions,
    'tobyBar': tobyBar,
    'moveMarks': moveMarks,
    'explorer': explorer,
    'arrowEvals': arrowEvals,
    'arrows': arrows.name,
  };

  /// Unknown or missing keys read as off.
  factory PlayHelpModules.fromJson(Map<String, Object?> json) {
    bool flag(String key) => json[key] == true;
    return PlayHelpModules(
      engineLines: flag('engineLines'),
      evalBar: flag('evalBar'),
      tobyPredictions: flag('tobyPredictions'),
      tobyBar: flag('tobyBar'),
      moveMarks: flag('moveMarks'),
      explorer: flag('explorer'),
      arrowEvals: flag('arrowEvals'),
      arrows:
          PlayHelpArrows.values.asNameMap()[json['arrows']] ??
          PlayHelpArrows.off,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlayHelpModules &&
      other.engineLines == engineLines &&
      other.evalBar == evalBar &&
      other.tobyPredictions == tobyPredictions &&
      other.tobyBar == tobyBar &&
      other.moveMarks == moveMarks &&
      other.explorer == explorer &&
      other.arrowEvals == arrowEvals &&
      other.arrows == arrows;

  @override
  int get hashCode => Object.hash(
    engineLines,
    evalBar,
    tobyPredictions,
    tobyBar,
    moveMarks,
    explorer,
    arrowEvals,
    arrows,
  );
}

final playHelpModulesProvider =
    NotifierProvider<PlayHelpModulesNotifier, PlayHelpModules>(
      PlayHelpModulesNotifier.new,
    );

/// The player's chosen help, saved on this device.
class PlayHelpModulesNotifier extends Notifier<PlayHelpModules> {
  bool _edited = false;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();

  @override
  PlayHelpModules build() {
    ref.onDispose(() => _disposed = true);
    unawaited(_restore());
    return const PlayHelpModules();
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_storageKey);
      if (_disposed || _edited || raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        state = PlayHelpModules.fromJson(decoded);
      }
    } catch (error) {
      debugPrint('Play help modules could not be restored: $error');
    }
  }

  void set(PlayHelpModules value) {
    _edited = true;
    if (value == state) return;
    state = value;
    final json = jsonEncode(value.toJson());
    _writes = _writes
        .then((_) async {
          final preferences = await SharedPreferences.getInstance();
          await preferences.setString(_storageKey, json);
        })
        .catchError((Object error) {
          debugPrint('Play help modules could not be saved: $error');
        });
  }

  void update(PlayHelpModules Function(PlayHelpModules current) change) =>
      set(change(state));
}

/// Whether the game on screen is a Play game whose help needs Stockfish.
/// The shared position search ([boardEvalProvider]) runs for it even when
/// the Board's own analysis is off: Play's help is chosen separately.
final playStockfishDemandProvider = Provider<bool>((ref) {
  if (!ref.watch(playHelpModulesProvider.select((m) => m.needsStockfish))) {
    return false;
  }
  final activeId = ref.watch(desktopTabsProvider.select((t) => t.activeId));
  return ref.watch(
    playSessionArgsByTabIdProvider.select((m) => m.containsKey(activeId)),
  );
});

/// The Board's analysis choices as a Play game's help reads them. Play
/// mounts the shared engine pane under an override of
/// [boardAnalysisPreferencesProvider] with this notifier, so the pane's own
/// controls (pause, the Stockfish and Toby switches, arrows) change the
/// player's help modules, never the Board's settings.
class PlayAnalysisSettings extends BoardAnalysisSettings {
  int? _lineIndex;
  late PlayHelpModulesNotifier _modules;
  late PlayHelpModules _current;

  @override
  BoardAnalysisPreferences build() {
    // Held from the build, so a second switch in the same frame still
    // reaches the modules while this rebuilds from the first.
    _modules = ref.watch(playHelpModulesProvider.notifier);
    _current = ref.watch(playHelpModulesProvider);
    return _preferencesFor(_current);
  }

  BoardAnalysisPreferences _preferencesFor(PlayHelpModules modules) =>
      BoardAnalysisPreferences(
        stockfishAnalysis: modules.engineLines,
        stockfishLineIndex:
            _lineIndex ?? const BoardAnalysisPreferences().stockfishLineIndex,
        tobyAnalysis: modules.tobyPredictions,
        stockfishBarChoice: modules.evalBar,
        arrowChoice: switch (modules.arrows) {
          PlayHelpArrows.off => BoardAnalysisArrows.off,
          PlayHelpArrows.stockfish => BoardAnalysisArrows.stockfish,
          PlayHelpArrows.toby => BoardAnalysisArrows.toby,
        },
      );

  void _change(PlayHelpModules Function(PlayHelpModules m) change) =>
      _modules.update(change);

  /// The pane's power button: off hides the engine and Toby in the rail,
  /// on brings the engine back.
  @override
  void setPaused(bool value) => _change(
    (m) =>
        value
            ? m.copyWith(engineLines: false, tobyPredictions: false)
            : m.copyWith(engineLines: true),
  );

  @override
  void setStockfishAnalysis(bool value) =>
      _change((m) => m.copyWith(engineLines: value));

  @override
  void setTobyAnalysis(bool value) =>
      _change((m) => m.copyWith(tobyPredictions: value));

  @override
  void setStockfishBar(bool value) =>
      _change((m) => m.copyWith(evalBar: value));

  @override
  void setArrows(BoardAnalysisArrows value) => _change(
    (m) => m.copyWith(
      arrows: switch (value) {
        BoardAnalysisArrows.off => PlayHelpArrows.off,
        BoardAnalysisArrows.stockfish => PlayHelpArrows.stockfish,
        BoardAnalysisArrows.toby => PlayHelpArrows.toby,
      },
    ),
  );

  @override
  void setStockfishLineIndex(int index) {
    _lineIndex = index;
    state = _preferencesFor(_current);
  }
}
