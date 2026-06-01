import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats PGN game dates separately from saved timestamps', () {
    expect(debugLibraryDisplayGameDate('2021.??.??'), '2021');
    expect(debugLibraryDisplayGameDate('2024.06.??'), '06.2024');
    expect(debugLibraryDisplayGameDate('2024.06.15'), '15.06.2024');
    expect(debugLibraryDisplayGameDate('?'), '—');
  });

  test('sorts library table by explicit reference-style columns', () {
    final rows = <SavedAnalysis>[
      _analysis(
        id: 'low-white',
        white: 'Carlsen',
        black: 'Alpha',
        whiteElo: '2500',
        blackElo: '2100',
        result: '1-0',
        event: 'Zurich',
        eco: 'C50',
        date: '2021.??.??',
        createdAt: DateTime(2026, 1, 2),
        updatedAt: DateTime(2026, 1, 3),
      ),
      _analysis(
        id: 'high-white',
        white: 'Anand',
        black: 'Beta',
        whiteElo: 2700,
        blackElo: 2300,
        result: '0-1',
        event: 'London',
        eco: 'B12',
        date: '2024.06.15',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 4),
      ),
    ];

    debugSortLibraryAnalysesForTest(rows, key: 'eloW', ascending: false);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'white', ascending: true);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'eloB', ascending: true);
    expect(rows.map((row) => row.id), ['low-white', 'high-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'result', ascending: true);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'black', ascending: false);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'eco', ascending: true);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'date', ascending: false);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'event', ascending: true);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'saved', ascending: true);
    expect(rows.map((row) => row.id), ['low-white', 'high-white']);

    debugSortLibraryAnalysesForTest(rows, key: 'number', ascending: true);
    expect(rows.map((row) => row.id), ['high-white', 'low-white']);
  });
}

SavedAnalysis _analysis({
  required String id,
  required String white,
  required String black,
  required Object whiteElo,
  required Object blackElo,
  required String result,
  required String event,
  required String eco,
  required String date,
  required DateTime createdAt,
  required DateTime updatedAt,
}) {
  return SavedAnalysis(
    id: id,
    userId: 'user',
    title: '$white vs $black',
    chessGame: ChessGame(
      gameId: id,
      startingFen: Chess.initial.fen,
      metadata: <String, dynamic>{
        'White': white,
        'Black': black,
        'WhiteElo': whiteElo,
        'BlackElo': blackElo,
        'Result': result,
        'Event': event,
        'ECO': eco,
        'Date': date,
      },
      mainline: const [],
    ),
    analysisState: const {},
    variationComments: const {},
    lastViewedPosition: -1,
    tags: const [],
    isFavorite: false,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}
