import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';

void main() {
  test('library table player formatter omits generic side placeholders', () {
    expect(libraryStandardTablePlayerName('White'), '');
    expect(libraryStandardTablePlayerName('Black'), '');
    expect(libraryStandardTablePlayerName('?'), '');
    expect(libraryStandardTablePlayerName('Carlsen, Magnus'), 'Carlsen, M.');
  });

  testWidgets('library table cells paint missing values as blank', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LibraryTablePlayerCell(name: 'White', federation: '', title: ''),
              LibraryTableRatingCell(rating: '?'),
              LibraryTableEcoCell(eco: '—'),
              LibraryTableResultPill(result: '*'),
            ],
          ),
        ),
      ),
    );

    for (final placeholder in const ['White', '?', '—', '•', '*']) {
      expect(find.text(placeholder), findsNothing);
    }
  });
}
