String? roundSlugDerivedKnockoutStageId({
  required String tourId,
  required String? roundSlug,
}) {
  final gameSlug = roundSlug?.trim().toLowerCase();
  if (gameSlug == null || gameSlug.isEmpty) return null;

  final stagePart =
      gameSlug.contains('--') ? gameSlug.split('--').first : gameSlug;
  final normalizedStage = stagePart
      .split(RegExp(r'[-_\s]+'))
      .where((part) => part.isNotEmpty)
      .join('-');
  if (normalizedStage.isEmpty) return null;

  return 'knockout-stage-$tourId-$normalizedStage';
}
