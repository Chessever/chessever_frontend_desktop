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

/// Resolves the next selected tournament id for a Current/Past grid intent.
///
/// Returns `null` when the grid is empty. When the selection does not move
/// (already at an edge), returns the same id that is currently resolved so
/// callers can keep the highlighter stable and still treat the key as handled.
String? nextTournamentEventGridSelectedId({
  required List<String> ids,
  required String? selectedId,
  required int columns,
  required TournamentEventGridNavigationIntent intent,
  required int pageRows,
}) {
  if (ids.isEmpty) return null;
  final base = resolveTournamentEventGridSelectionIndex(
    ids: ids,
    selectedId: selectedId,
  );
  final next = moveTournamentEventGridSelectionIndex(
    currentIndex: base,
    itemCount: ids.length,
    columns: columns,
    intent: intent,
    pageRows: pageRows,
  );
  return ids[next];
}

/// Whether a Current/Past grid [HardwareKeyboard] host may intercept a key.
///
/// Persistent tab stacks keep inactive panes mounted under [TickerMode]
/// disabled. Those hosts must return false so the active pane owns arrows /
/// Page / Home / End (same contract as For You `activeId` gating and
/// [PaneKeyboardScroll] / grouped game keyboard TickerMode checks).
bool shouldTournamentEventGridHandleGlobalKey({
  required bool mounted,
  required bool tickerModeEnabled,
  required bool hostHasFocus,
  required bool hasNavigationModifier,
  required bool hasEditableTextFocus,
  required bool isRelevantKey,
}) {
  if (!mounted || !tickerModeEnabled) return false;
  // When the host Focus already owns the event, leave it to onKeyEvent so we
  // do not advance selection twice.
  if (hostHasFocus) return false;
  if (hasNavigationModifier || hasEditableTextFocus) return false;
  return isRelevantKey;
}
