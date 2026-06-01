import 'package:chessever/desktop/utils/tournament_event_grid_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('calculateTournamentEventGridColumns', () {
    test('uses three columns for wide desktop tournament discovery', () {
      expect(calculateTournamentEventGridColumns(1200), 3);
      expect(calculateTournamentEventGridColumns(980), 3);
    });

    test('uses two columns for smaller desktop panes', () {
      expect(calculateTournamentEventGridColumns(979), 2);
      expect(calculateTournamentEventGridColumns(640), 2);
    });

    test('uses one column instead of horizontal scrolling on narrow panes', () {
      expect(calculateTournamentEventGridColumns(639), 1);
      expect(calculateTournamentEventGridColumns(320), 1);
    });
  });

  test('tournamentEventGridChildAspectRatio keeps cards readable', () {
    final wide = tournamentEventGridChildAspectRatio(width: 1160, columns: 3);
    final medium = tournamentEventGridChildAspectRatio(width: 760, columns: 2);
    final narrow = tournamentEventGridChildAspectRatio(width: 460, columns: 1);

    expect(wide, greaterThan(2.9));
    expect(medium, greaterThan(2.9));
    expect(narrow, greaterThan(3.5));
  });

  group('resolveTournamentEventGridSelectionIndex', () {
    test('keeps the selected event when it is still visible', () {
      expect(
        resolveTournamentEventGridSelectionIndex(
          ids: const ['norway', 'limburg', 'chicago'],
          selectedId: 'limburg',
        ),
        1,
      );
    });

    test('falls back to the first visible event for stale selections', () {
      expect(
        resolveTournamentEventGridSelectionIndex(
          ids: const ['norway', 'limburg', 'chicago'],
          selectedId: 'missing-event',
        ),
        0,
      );
      expect(
        resolveTournamentEventGridSelectionIndex(
          ids: const ['norway', 'limburg', 'chicago'],
          selectedId: null,
        ),
        0,
      );
    });

    test('returns -1 for empty grids', () {
      expect(
        resolveTournamentEventGridSelectionIndex(
          ids: const [],
          selectedId: 'missing-event',
        ),
        -1,
      );
    });
  });

  group('moveTournamentEventGridSelectionIndex', () {
    test('moves through a three-column grid by row and column', () {
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 4,
          itemCount: 9,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.right,
          pageRows: 5,
        ),
        5,
      );
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 4,
          itemCount: 9,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.left,
          pageRows: 5,
        ),
        3,
      );
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 4,
          itemCount: 9,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.down,
          pageRows: 5,
        ),
        7,
      );
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 4,
          itemCount: 9,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.up,
          pageRows: 5,
        ),
        1,
      );
    });

    test('clamps paging and edge navigation inside the visible events', () {
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 1,
          itemCount: 10,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.pageDown,
          pageRows: 3,
        ),
        9,
      );
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 2,
          itemCount: 10,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.pageUp,
          pageRows: 3,
        ),
        0,
      );
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 5,
          itemCount: 10,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.home,
          pageRows: 3,
        ),
        0,
      );
      expect(
        moveTournamentEventGridSelectionIndex(
          currentIndex: 5,
          itemCount: 10,
          columns: 3,
          intent: TournamentEventGridNavigationIntent.end,
          pageRows: 3,
        ),
        9,
      );
    });
  });
}
