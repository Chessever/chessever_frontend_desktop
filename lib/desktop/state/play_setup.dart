import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_strength.dart';

/// Per-tab Play setup state. The Play pane reads/mutates this through
/// [playSetupProvider]; once the user hits "Start Game" the active session
/// reads a frozen snapshot of the [PlayConfig] and drives its own state
/// (see `play_session.dart`, added in task #4).
class PlaySetupNotifier extends StateNotifier<PlayConfig> {
  PlaySetupNotifier() : super(PlayConfig.defaults);

  void setEngine(BotEngineKind engine) {
    if (state.engine == engine) return;
    state = state.copyWith(
      engine: engine,
      elo: _clampEloFor(engine, state.elo),
    );
  }

  void setElo(int elo) {
    state = state.copyWith(elo: _clampEloFor(state.engine, elo));
  }

  /// Pick a preset from the grid. Snaps base + increment to the preset and
  /// remembers the category so the picker shows the right tab.
  void applyPreset(TimeControlPreset preset) {
    state = state.copyWith(
      category: preset.category,
      baseSeconds: preset.baseSeconds,
      incrementSeconds: preset.incrementSeconds,
    );
  }

  /// Free-form time control — switches the picker into Custom mode.
  void setCustomTime({
    required int baseSeconds,
    required int incrementSeconds,
  }) {
    final clampedBase = baseSeconds.clamp(10, 6 * 3600); // 10s..6h
    final clampedInc = incrementSeconds.clamp(0, 180);
    state = state.copyWith(
      category: TimeControlCategory.custom,
      baseSeconds: clampedBase,
      incrementSeconds: clampedInc,
    );
  }

  void setColor(PlayColorChoice color) {
    state = state.copyWith(color: color);
  }

  /// Seed setup with a starting position (used by "Play from here"). If the
  /// caller has the path to this position, keep those moves so the launched
  /// game's notation is prefilled up to the board the user chose.
  void seedFromFen(
    String fen, {
    String? startingFen,
    List<String> startingMovesUci = const <String>[],
  }) {
    state = state.copyWith(
      startingFen: startingFen ?? fen,
      startingMovesUci: List<String>.unmodifiable(startingMovesUci),
    );
  }

  void clearStartingSeed() {
    state = state.copyWith(clearStartingFen: true, clearStartingMoves: true);
  }

  /// Each engine exposes strength differently. Stockfish can clamp to its
  /// supported UCI_Elo range; Leela/Maia snap to finite play modes so the UI
  /// does not pretend they support arbitrary slider values.
  int _clampEloFor(BotEngineKind engine, int elo) {
    return normalizePlayStrength(engine, elo);
  }
}

/// Setup state for the Play pane. Kept alive so "Play from here" can seed the
/// form before the freshly opened Play tab has mounted its widgets. Setup is
/// intentionally shared across Play tabs — it's a "last-used" form, not a
/// per-game artefact; once the user hits Start, the snapshot is frozen into
/// the per-tab `playSessionArgsByTabIdProvider` entry and the form may
/// continue to be edited for another tab without disturbing the live game.
final playSetupProvider = StateNotifierProvider<PlaySetupNotifier, PlayConfig>(
  (ref) => PlaySetupNotifier(),
);

@visibleForTesting
PlayConfig debugDefaultConfig() => PlayConfig.defaults;
