enum TournamentEventGridNavigationIntent {
  left,
  right,
  up,
  down,
  pageUp,
  pageDown,
  home,
  end,
}

int calculateTournamentEventGridColumns(double width) {
  if (width >= 980) {
    return 3;
  }
  if (width >= 640) {
    return 2;
  }
  return 1;
}

double tournamentEventGridChildAspectRatio({
  required double width,
  required int columns,
}) {
  final safeColumns = columns.clamp(1, 3);
  const spacing = 12.0;
  const targetHeight = 124.0;
  final cardWidth = (width - spacing * (safeColumns - 1)) / safeColumns;
  return cardWidth / targetHeight;
}

int resolveTournamentEventGridSelectionIndex({
  required List<String> ids,
  required String? selectedId,
}) {
  if (ids.isEmpty) {
    return -1;
  }
  if (selectedId == null) {
    return 0;
  }
  final index = ids.indexOf(selectedId);
  return index < 0 ? 0 : index;
}

int moveTournamentEventGridSelectionIndex({
  required int currentIndex,
  required int itemCount,
  required int columns,
  required TournamentEventGridNavigationIntent intent,
  required int pageRows,
}) {
  if (itemCount <= 0) {
    return -1;
  }
  final base = currentIndex.clamp(0, itemCount - 1).toInt();
  final safeColumns = columns.clamp(1, itemCount).toInt();
  final safePageRows = pageRows < 1 ? 1 : pageRows;
  final target = switch (intent) {
    TournamentEventGridNavigationIntent.right => base + 1,
    TournamentEventGridNavigationIntent.left => base - 1,
    TournamentEventGridNavigationIntent.down => base + safeColumns,
    TournamentEventGridNavigationIntent.up => base - safeColumns,
    TournamentEventGridNavigationIntent.pageDown =>
      base + safeColumns * safePageRows,
    TournamentEventGridNavigationIntent.pageUp =>
      base - safeColumns * safePageRows,
    TournamentEventGridNavigationIntent.home => 0,
    TournamentEventGridNavigationIntent.end => itemCount - 1,
  };
  return target.clamp(0, itemCount - 1).toInt();
}
