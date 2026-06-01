import 'package:flutter/foundation.dart';

/// Engines users can pick to play against. The catalog of where the binaries
/// live, what URLs to fetch from, and what UCI options to feed each one is in
/// [engine_catalog.dart] (added in a later task). This enum is the stable
/// identifier the setup UI and Play session pass around.
enum BotEngineKind {
  /// Stockfish. The desktop facade already drives this for analysis; for
  /// play we open a separate process so analysis and the opponent don't
  /// share state. Skill is throttled via UCI_LimitStrength + UCI_Elo.
  stockfish,

  /// Leela Chess Zero (lc0). Neural-net engine; users choose a finite play
  /// profile because lc0 has no Stockfish-style arbitrary UCI_Elo throttle.
  leela,

  /// Maia. Human-like neural opponent; Maia 3 runs from a local ONNX model
  /// and is rating-conditioned instead of exposing a generic ELO slider.
  maia,
}

extension BotEngineKindLabel on BotEngineKind {
  String get displayName {
    switch (this) {
      case BotEngineKind.stockfish:
        return 'Stockfish';
      case BotEngineKind.leela:
        return 'Leela (lc0)';
      case BotEngineKind.maia:
        return 'Maia';
    }
  }

  /// Short one-liner shown under the engine name in the picker.
  String get tagline {
    switch (this) {
      case BotEngineKind.stockfish:
        return 'Classical search with an exact UCI_Elo slider.';
      case BotEngineKind.leela:
        return 'Neural-net play profiles shaped by temperature and nodes.';
      case BotEngineKind.maia:
        return 'Human cohorts trained from online move choices.';
    }
  }
}

/// Category preset for the time-control picker. Selecting a category fills
/// the [PlayConfig.baseSeconds] / [PlayConfig.incrementSeconds] from the
/// matching preset; the user can still tweak the raw values afterwards.
enum TimeControlCategory { bullet, blitz, rapid, classical, custom }

extension TimeControlCategoryLabel on TimeControlCategory {
  String get displayName {
    switch (this) {
      case TimeControlCategory.bullet:
        return 'Bullet';
      case TimeControlCategory.blitz:
        return 'Blitz';
      case TimeControlCategory.rapid:
        return 'Rapid';
      case TimeControlCategory.classical:
        return 'Classical';
      case TimeControlCategory.custom:
        return 'Custom';
    }
  }
}

/// One slot in the time-control preset grid. `base` is per-side starting
/// clock; `increment` is Fischer increment per move.
@immutable
class TimeControlPreset {
  const TimeControlPreset({
    required this.category,
    required this.baseSeconds,
    required this.incrementSeconds,
  });

  final TimeControlCategory category;
  final int baseSeconds;
  final int incrementSeconds;

  /// Canonical "m+s" shorthand, e.g. `1+0`, `3+2`, `15+10`. Uses minutes when
  /// base is a whole number of minutes, falls back to seconds otherwise so
  /// 30-second bullet renders as `30s+0` rather than `0+0`.
  String get shorthand {
    if (baseSeconds % 60 == 0) {
      return '${baseSeconds ~/ 60}+$incrementSeconds';
    }
    return '${baseSeconds}s+$incrementSeconds';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TimeControlPreset &&
            other.category == category &&
            other.baseSeconds == baseSeconds &&
            other.incrementSeconds == incrementSeconds;
  }

  @override
  int get hashCode => Object.hash(category, baseSeconds, incrementSeconds);
}

/// The presets shown in each category. Mirrors what chess.com surfaces by
/// default — close enough that users have muscle memory for the speeds.
const Map<TimeControlCategory, List<TimeControlPreset>> kTimeControlPresets = {
  TimeControlCategory.bullet: [
    TimeControlPreset(
      category: TimeControlCategory.bullet,
      baseSeconds: 60,
      incrementSeconds: 0,
    ),
    TimeControlPreset(
      category: TimeControlCategory.bullet,
      baseSeconds: 60,
      incrementSeconds: 1,
    ),
    TimeControlPreset(
      category: TimeControlCategory.bullet,
      baseSeconds: 120,
      incrementSeconds: 1,
    ),
  ],
  TimeControlCategory.blitz: [
    TimeControlPreset(
      category: TimeControlCategory.blitz,
      baseSeconds: 180,
      incrementSeconds: 0,
    ),
    TimeControlPreset(
      category: TimeControlCategory.blitz,
      baseSeconds: 180,
      incrementSeconds: 2,
    ),
    TimeControlPreset(
      category: TimeControlCategory.blitz,
      baseSeconds: 300,
      incrementSeconds: 0,
    ),
    TimeControlPreset(
      category: TimeControlCategory.blitz,
      baseSeconds: 300,
      incrementSeconds: 5,
    ),
  ],
  TimeControlCategory.rapid: [
    TimeControlPreset(
      category: TimeControlCategory.rapid,
      baseSeconds: 600,
      incrementSeconds: 0,
    ),
    TimeControlPreset(
      category: TimeControlCategory.rapid,
      baseSeconds: 900,
      incrementSeconds: 10,
    ),
    TimeControlPreset(
      category: TimeControlCategory.rapid,
      baseSeconds: 1800,
      incrementSeconds: 0,
    ),
  ],
  TimeControlCategory.classical: [
    TimeControlPreset(
      category: TimeControlCategory.classical,
      baseSeconds: 1800,
      incrementSeconds: 30,
    ),
    TimeControlPreset(
      category: TimeControlCategory.classical,
      baseSeconds: 3600,
      incrementSeconds: 0,
    ),
    TimeControlPreset(
      category: TimeControlCategory.classical,
      baseSeconds: 5400,
      incrementSeconds: 30,
    ),
  ],
};

/// Color the human plays. `random` is resolved at game start.
enum PlayColorChoice { white, black, random }

extension PlayColorChoiceLabel on PlayColorChoice {
  String get displayName {
    switch (this) {
      case PlayColorChoice.white:
        return 'White';
      case PlayColorChoice.black:
        return 'Black';
      case PlayColorChoice.random:
        return 'Random';
    }
  }
}

/// Snapshot of everything the user picks on the Play setup screen. The Play
/// session reads this once at game start; mutating it afterwards has no
/// effect on the live game.
@immutable
class PlayConfig {
  const PlayConfig({
    required this.engine,
    required this.elo,
    required this.category,
    required this.baseSeconds,
    required this.incrementSeconds,
    required this.color,
    this.blackBaseSeconds,
    this.blackIncrementSeconds,
    this.startClockImmediately = false,
    this.startingFen,
    this.startingMovesUci = const <String>[],
  });

  final BotEngineKind engine;

  /// Opponent strength calibration. Stockfish treats this as exact UCI_Elo;
  /// Leela and Maia snap it to finite play modes in `play_strength.dart`.
  final int elo;

  final TimeControlCategory category;

  /// White's base starting seconds. Also used as the symmetric value when
  /// [blackBaseSeconds] is null.
  final int baseSeconds;

  /// White's Fischer increment per move (seconds). Also used as the symmetric
  /// value when [blackIncrementSeconds] is null.
  final int incrementSeconds;

  /// Optional asymmetric override for Black's base clock. When null, Black
  /// uses [baseSeconds] (symmetric clock).
  final int? blackBaseSeconds;

  /// Optional asymmetric override for Black's increment. When null, Black
  /// uses [incrementSeconds] (symmetric increment).
  final int? blackIncrementSeconds;

  /// Effective per-side values — read these instead of the raw fields when
  /// seeding the session clock or driving UCI `go wtime/btime/winc/binc`.
  int get whiteBaseSeconds => baseSeconds;
  int get effectiveBlackBaseSeconds => blackBaseSeconds ?? baseSeconds;
  int get whiteIncrementSeconds => incrementSeconds;
  int get effectiveBlackIncrementSeconds =>
      blackIncrementSeconds ?? incrementSeconds;

  /// True when the two sides do not share the same base+increment.
  bool get isAsymmetricClock =>
      effectiveBlackBaseSeconds != baseSeconds ||
      effectiveBlackIncrementSeconds != incrementSeconds;

  final PlayColorChoice color;

  /// When true, the side-to-move clock starts as soon as the session is
  /// created. Single casual games keep the old first-move clock behavior;
  /// tournament games use this so the pairing is live immediately.
  final bool startClockImmediately;

  /// Optional override starting position — set by "Play from here" so the
  /// game continues from the user's current board state instead of the
  /// initial position. When [startingMovesUci] is non-empty, this is the root
  /// FEN those moves replay from.
  final String? startingFen;

  /// UCI moves already played before a "Play from here" game begins. These
  /// are part of the visible notation and engine position, but they are seeded
  /// before the first live move.
  final List<String> startingMovesUci;

  bool get hasStartingPositionSeed =>
      startingFen != null || startingMovesUci.isNotEmpty;

  String get timeControlShorthand =>
      TimeControlPreset(
        category: category,
        baseSeconds: baseSeconds,
        incrementSeconds: incrementSeconds,
      ).shorthand;

  PlayConfig copyWith({
    BotEngineKind? engine,
    int? elo,
    TimeControlCategory? category,
    int? baseSeconds,
    int? incrementSeconds,
    int? blackBaseSeconds,
    int? blackIncrementSeconds,
    PlayColorChoice? color,
    bool? startClockImmediately,
    String? startingFen,
    List<String>? startingMovesUci,
    bool clearStartingFen = false,
    bool clearStartingMoves = false,
    bool clearBlackBaseSeconds = false,
    bool clearBlackIncrementSeconds = false,
  }) {
    return PlayConfig(
      engine: engine ?? this.engine,
      elo: elo ?? this.elo,
      category: category ?? this.category,
      baseSeconds: baseSeconds ?? this.baseSeconds,
      incrementSeconds: incrementSeconds ?? this.incrementSeconds,
      blackBaseSeconds:
          clearBlackBaseSeconds
              ? null
              : (blackBaseSeconds ?? this.blackBaseSeconds),
      blackIncrementSeconds:
          clearBlackIncrementSeconds
              ? null
              : (blackIncrementSeconds ?? this.blackIncrementSeconds),
      color: color ?? this.color,
      startClockImmediately:
          startClockImmediately ?? this.startClockImmediately,
      startingFen: clearStartingFen ? null : (startingFen ?? this.startingFen),
      startingMovesUci:
          clearStartingMoves
              ? const <String>[]
              : (startingMovesUci ?? this.startingMovesUci),
    );
  }

  static const PlayConfig defaults = PlayConfig(
    engine: BotEngineKind.stockfish,
    elo: 1500,
    category: TimeControlCategory.blitz,
    baseSeconds: 300,
    incrementSeconds: 0,
    color: PlayColorChoice.random,
  );
}
