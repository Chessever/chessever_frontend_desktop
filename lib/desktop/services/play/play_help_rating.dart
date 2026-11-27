/// The lowest share of a rating gain a game with help keeps.
const double kPlayHelpMinGainFactor = 0.25;

/// The share of a rating gain a saved game keeps for the help it used, read
/// from its record (`metadata.help.gainFactor`, written by the game from
/// `playHelpGainFactor`). 1 when it carries none: older games, and games
/// played without help.
double playHelpGainFactorFromMetadata(Map<String, dynamic> metadata) {
  final help = metadata['help'];
  if (help is! Map) return 1;
  final factor = help['gainFactor'];
  if (factor is! num) return 1;
  return factor.toDouble().clamp(kPlayHelpMinGainFactor, 1.0);
}
