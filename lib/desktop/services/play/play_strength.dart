import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/play/play_models.dart';

/// One selectable opponent-strength mode.
///
/// Stockfish exposes a real UCI_Elo range, so it uses a continuous slider.
/// Leela and Maia do not expose that same arbitrary ELO throttle: Leela is
/// shaped through search/temperature budgets and Maia is rating-conditioned.
/// Their UI therefore presents finite play modes while keeping a numeric
/// calibration value for existing rating math, bot identities, and PGN tags.
@immutable
class PlayStrengthOption {
  const PlayStrengthOption({
    required this.value,
    required this.label,
    required this.description,
  });

  final int value;
  final String label;
  final String description;
}

const List<PlayStrengthOption> _leelaModes = [
  PlayStrengthOption(
    value: 1000,
    label: 'Explorer',
    description: 'High-temperature neural play with a tiny node budget.',
  ),
  PlayStrengthOption(
    value: 1600,
    label: 'Club neural',
    description: 'Human-paced searches with a wider tactical horizon.',
  ),
  PlayStrengthOption(
    value: 2200,
    label: 'Tournament',
    description: 'Lower temperature and deeper move selection.',
  ),
  PlayStrengthOption(
    value: 2800,
    label: 'Master',
    description: 'Restrained policy noise and a strong node budget.',
  ),
  PlayStrengthOption(
    value: 3200,
    label: 'Full net',
    description: 'Maximum local Leela budget for the installed network.',
  ),
];

const List<PlayStrengthOption> _maiaModes = [
  PlayStrengthOption(
    value: 600,
    label: 'Maia 600',
    description: 'New-player human move distribution.',
  ),
  PlayStrengthOption(
    value: 1000,
    label: 'Maia 1000',
    description: 'Casual online mistakes and simple plans.',
  ),
  PlayStrengthOption(
    value: 1400,
    label: 'Maia 1400',
    description: 'Club-level human choices with tactical misses.',
  ),
  PlayStrengthOption(
    value: 1800,
    label: 'Maia 1800',
    description: 'Stronger human-like calculation and opening sense.',
  ),
  PlayStrengthOption(
    value: 2200,
    label: 'Maia 2200',
    description: 'Advanced human pattern play.',
  ),
  PlayStrengthOption(
    value: 2600,
    label: 'Maia 2600',
    description: 'Top-end Maia rating conditioning.',
  ),
];

bool usesExactEloSlider(BotEngineKind engine) =>
    engine == BotEngineKind.stockfish;

(int, int) playStrengthRangeFor(BotEngineKind engine) {
  return switch (engine) {
    BotEngineKind.stockfish => (1320, 3190),
    BotEngineKind.leela => (_leelaModes.first.value, _leelaModes.last.value),
    BotEngineKind.maia => (_maiaModes.first.value, _maiaModes.last.value),
  };
}

List<PlayStrengthOption> playStrengthOptionsFor(BotEngineKind engine) {
  return switch (engine) {
    BotEngineKind.stockfish => const <PlayStrengthOption>[],
    BotEngineKind.leela => _leelaModes,
    BotEngineKind.maia => _maiaModes,
  };
}

int normalizePlayStrength(BotEngineKind engine, int value) {
  if (usesExactEloSlider(engine)) {
    final (lo, hi) = playStrengthRangeFor(engine);
    return value.clamp(lo, hi).toInt();
  }
  return nearestPlayStrengthOption(engine, value).value;
}

PlayStrengthOption nearestPlayStrengthOption(BotEngineKind engine, int value) {
  final options = playStrengthOptionsFor(engine);
  if (options.isEmpty) {
    final normalized = normalizePlayStrength(BotEngineKind.stockfish, value);
    return PlayStrengthOption(
      value: normalized,
      label: '$normalized ELO',
      description: 'Exact Stockfish UCI_Elo target.',
    );
  }

  var best = options.first;
  var bestDistance = (value - best.value).abs();
  for (final option in options.skip(1)) {
    final distance = (value - option.value).abs();
    if (distance < bestDistance) {
      best = option;
      bestDistance = distance;
    }
  }
  return best;
}

String playStrengthControlTitle(BotEngineKind engine) {
  return switch (engine) {
    BotEngineKind.stockfish => 'Opponent ELO',
    BotEngineKind.leela => 'Leela mode',
    BotEngineKind.maia => 'Maia cohort',
  };
}

String playStrengthControlCaption(BotEngineKind engine) {
  return switch (engine) {
    BotEngineKind.stockfish =>
      'Exact UCI_Elo throttling through Stockfish LimitStrength.',
    BotEngineKind.leela =>
      'Leela uses search profiles, not an arbitrary ELO slider.',
    BotEngineKind.maia =>
      'Maia uses rating-conditioned human cohorts, not an arbitrary slider.',
  };
}

String playStrengthLabel(BotEngineKind engine, int value) {
  if (usesExactEloSlider(engine)) {
    return '${normalizePlayStrength(engine, value)} ELO';
  }
  return nearestPlayStrengthOption(engine, value).label;
}

String playStrengthStartSummary(BotEngineKind engine, int value) {
  return switch (engine) {
    BotEngineKind.stockfish => playStrengthLabel(engine, value),
    BotEngineKind.leela =>
      '${nearestPlayStrengthOption(engine, value).label} profile',
    BotEngineKind.maia => nearestPlayStrengthOption(engine, value).label,
  };
}
