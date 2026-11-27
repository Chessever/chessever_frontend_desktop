import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/state/board_analysis_preferences.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/play_settings_cloud.dart';
import 'package:chessever/desktop/state/toby_enabled.dart';

const _storageKey = 'desktop.play.helpModules.v1';
const _updatedAtKey = 'desktop.play.helpModules.v1.updatedAt';

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
    this.threats = false,
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

  /// Kept for saved choices written by older builds. The "Show threat"
  /// button is now always beside the player's clock (and on X), so this
  /// no longer gates anything; see [playThreatShownProvider].
  final bool threats;

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

  /// Whether any help module is on. The legacy [threats] flag shows
  /// nothing, so it does not count: a saved `threats: true` alone must not
  /// cut a win's gain or charge a peek or hint that reveals nothing.
  bool get anyOn => chosenModules.isNotEmpty;

  PlayHelpModules copyWith({
    bool? engineLines,
    bool? evalBar,
    bool? tobyPredictions,
    bool? tobyBar,
    bool? moveMarks,
    bool? explorer,
    bool? arrowEvals,
    bool? threats,
    PlayHelpArrows? arrows,
  }) => PlayHelpModules(
    engineLines: engineLines ?? this.engineLines,
    evalBar: evalBar ?? this.evalBar,
    tobyPredictions: tobyPredictions ?? this.tobyPredictions,
    tobyBar: tobyBar ?? this.tobyBar,
    moveMarks: moveMarks ?? this.moveMarks,
    explorer: explorer ?? this.explorer,
    arrowEvals: arrowEvals ?? this.arrowEvals,
    threats: threats ?? this.threats,
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
    'threats': threats,
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
      threats: flag('threats'),
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
      other.threats == threats &&
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
    threats,
    arrows,
  );
}

/// One piece of the chosen help, revealed on its own by a peek or a hint
/// (or with the rest of it). Same order as the Live help switches.
enum PlayHelpModule {
  engineLines('Engine lines'),
  evalBar('Eval bar'),
  tobyPredictions('Toby Predicts'),
  tobyBar('Toby bar'),
  moveMarks('Move marks'),
  explorer('Opening explorer'),
  arrowEvals('Eval on my arrows'),
  arrows('Arrows');

  const PlayHelpModule(this.label);

  final String label;

  /// Whether the player switched this module on in [modules].
  bool chosenIn(PlayHelpModules modules) => switch (this) {
    PlayHelpModule.engineLines => modules.engineLines,
    PlayHelpModule.evalBar => modules.evalBar,
    PlayHelpModule.tobyPredictions => modules.tobyPredictions,
    PlayHelpModule.tobyBar => modules.tobyBar,
    PlayHelpModule.moveMarks => modules.moveMarks,
    PlayHelpModule.explorer => modules.explorer,
    PlayHelpModule.arrowEvals => modules.arrowEvals,
    PlayHelpModule.arrows => modules.arrows != PlayHelpArrows.off,
  };

  /// The label for [modules]' choice: arrows name their source.
  String labelIn(PlayHelpModules modules) => switch (this) {
    PlayHelpModule.arrows => switch (modules.arrows) {
      PlayHelpArrows.stockfish => 'Stockfish arrows',
      PlayHelpArrows.toby => 'Toby arrows',
      PlayHelpArrows.off => label,
    },
    _ => label,
  };
}

extension PlayHelpModulesPieces on PlayHelpModules {
  /// The modules switched on, in [PlayHelpModule] order.
  List<PlayHelpModule> get chosenModules => [
    for (final module in PlayHelpModule.values)
      if (module.chosenIn(this)) module,
  ];

  /// These choices with only [revealed] kept on. Arrows keep their chosen
  /// source. All of them revealed is these choices as they are.
  PlayHelpModules onlyRevealed(Set<PlayHelpModule> revealed) {
    if (revealed.length == PlayHelpModule.values.length) return this;
    bool keep(PlayHelpModule module, bool on) =>
        on && revealed.contains(module);
    return copyWith(
      engineLines: keep(PlayHelpModule.engineLines, engineLines),
      evalBar: keep(PlayHelpModule.evalBar, evalBar),
      tobyPredictions: keep(PlayHelpModule.tobyPredictions, tobyPredictions),
      tobyBar: keep(PlayHelpModule.tobyBar, tobyBar),
      moveMarks: keep(PlayHelpModule.moveMarks, moveMarks),
      explorer: keep(PlayHelpModule.explorer, explorer),
      arrowEvals: keep(PlayHelpModule.arrowEvals, arrowEvals),
      threats: false,
      arrows:
          revealed.contains(PlayHelpModule.arrows)
              ? arrows
              : PlayHelpArrows.off,
    );
  }
}

final playHelpModulesProvider =
    NotifierProvider<PlayHelpModulesNotifier, PlayHelpModules>(
      PlayHelpModulesNotifier.new,
    );

/// [modules] as a game shows them: with Toby off (the account's switch)
/// none of Toby's help is on, and his arrows are none rather than
/// Stockfish's, so turning Toby off never adds engine help to a game.
PlayHelpModules playHelpModulesShown(
  PlayHelpModules modules, {
  required bool tobyEnabled,
}) =>
    tobyEnabled
        ? modules
        : modules.copyWith(
          tobyPredictions: false,
          tobyBar: false,
          arrows:
              modules.arrows == PlayHelpArrows.toby
                  ? PlayHelpArrows.off
                  : modules.arrows,
        );

/// The player's chosen help, saved on this device and on the player's
/// profile row ([PlaySettingsCloudSync]), so it follows them to other
/// devices and apps. Its state is the help as shown
/// ([playHelpModulesShown]); Toby's modules are kept in the saved choice
/// while Toby is off, and come back with him.
class PlayHelpModulesNotifier extends Notifier<PlayHelpModules> {
  bool _edited = false;
  bool _disposed = false;
  Future<void> _writes = Future<void>.value();
  PlayHelpModules _chosen = const PlayHelpModules();
  final Completer<void> _restored = Completer<void>();
  DateTime? _updatedAt;

  bool get _tobyOn => ref.read(tobyEnabledProvider);

  /// When the choice was last changed here or taken from the server; null
  /// when it never was.
  DateTime? get updatedAt => _updatedAt;

  /// The saved choice, Toby's modules included while Toby is off.
  PlayHelpModules get chosen => _chosen;

  /// Completes once the saved choice was read.
  Future<void> get restored => _restored.future;

  @override
  PlayHelpModules build() {
    ref.onDispose(() => _disposed = true);
    ref.listen<bool>(tobyEnabledProvider, (_, on) {
      state = playHelpModulesShown(_chosen, tobyEnabled: on);
    });
    unawaited(_restore());
    return playHelpModulesShown(_chosen, tobyEnabled: _tobyOn);
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_storageKey);
      final at = parsePlaySettingsTime(preferences.getString(_updatedAtKey));
      if (_disposed || _edited) return;
      _updatedAt = at;
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        _chosen = PlayHelpModules.fromJson(decoded);
        state = playHelpModulesShown(_chosen, tobyEnabled: _tobyOn);
      }
    } catch (error) {
      debugPrint('Play help modules could not be restored: $error');
    } finally {
      if (!_restored.isCompleted) _restored.complete();
      if (!_disposed) ref.read(playSettingsCloudProvider).start();
    }
  }

  void set(PlayHelpModules value) {
    _edited = true;
    if (value == state) return;
    if (!_tobyOn) {
      // Toby's switches are hidden: keep his saved choices for later.
      value = value.copyWith(
        tobyPredictions: _chosen.tobyPredictions,
        tobyBar: _chosen.tobyBar,
        arrows: value.arrows == state.arrows ? _chosen.arrows : value.arrows,
      );
    }
    _chosen = value;
    state = playHelpModulesShown(value, tobyEnabled: _tobyOn);
    _updatedAt = DateTime.now().toUtc();
    _save(value, _updatedAt);
    ref.read(playSettingsCloudProvider).localChanged();
  }

  void update(PlayHelpModules Function(PlayHelpModules current) change) =>
      set(change(state));

  /// Takes the choice saved on the server at [at]. Skipped (returns false)
  /// when the choice changed here since the sync read [expectedLocalAt]:
  /// the newer local change goes up on the next pass instead.
  bool adoptRemote(
    PlayHelpModules value,
    DateTime? at, {
    required DateTime? expectedLocalAt,
  }) {
    if (_disposed || _updatedAt != expectedLocalAt) return false;
    _edited = true;
    _updatedAt = at;
    _chosen = value;
    final shown = playHelpModulesShown(value, tobyEnabled: _tobyOn);
    if (shown != state) state = shown;
    _save(value, at);
    return true;
  }

  void _save(PlayHelpModules value, DateTime? at) {
    final json = jsonEncode(value.toJson());
    final stamp = at?.toUtc().toIso8601String();
    _writes = _writes
        .then((_) async {
          final preferences = await SharedPreferences.getInstance();
          await preferences.setString(_storageKey, json);
          if (stamp == null) {
            await preferences.remove(_updatedAtKey);
          } else {
            await preferences.setString(_updatedAtKey, stamp);
          }
        })
        .catchError((Object error) {
          debugPrint('Play help modules could not be saved: $error');
        });
  }
}

/// Whether the game on screen is a Play game whose help needs Stockfish.
/// The shared position search ([boardEvalProvider]) runs for it even when
/// the Board's own analysis is off: Play's help is chosen separately.
/// Whether the player has asked to see the opponent's threat in each Play
/// tab. The button is always on screen during a game; it stays as the
/// player left it for the next game in the same tab.
final playThreatShownProvider = StateProvider.family<bool, String>(
  (ref, tabId) => false,
);

final playStockfishDemandProvider = Provider<bool>((ref) {
  final activeId = ref.watch(desktopTabsProvider.select((t) => t.activeId));
  final modulesNeedIt = ref.watch(
    playHelpModulesProvider.select((m) => m.needsStockfish),
  );
  // The threat button searches only while the player has it pressed.
  final threatShown =
      activeId != null && ref.watch(playThreatShownProvider(activeId));
  if (!modulesNeedIt && !threatShown) return false;
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
  /// With a game's [tabId], the pane reads the help on screen in it
  /// ([playHelpShownProvider]): a peek at Toby alone shows Toby without
  /// Stockfish's lines. Its switches still change the chosen modules.
  PlayAnalysisSettings([this.tabId]);

  final String? tabId;

  int? _lineIndex;
  late PlayHelpModulesNotifier _modules;
  late PlayHelpModules _current;

  @override
  BoardAnalysisPreferences build() {
    // Held from the build, so a second switch in the same frame still
    // reaches the modules while this rebuilds from the first.
    _modules = ref.watch(playHelpModulesProvider.notifier);
    final id = tabId;
    _current =
        id == null
            ? ref.watch(playHelpModulesProvider)
            : ref.watch(playHelpShownProvider(id));
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
