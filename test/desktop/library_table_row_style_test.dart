import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/theme/app_theme.dart';

void main() {
  test('library table player formatter omits generic side placeholders', () {
    expect(libraryStandardTablePlayerName('White'), '');
    expect(libraryStandardTablePlayerName('Black'), '');
    expect(libraryStandardTablePlayerName('?'), '');
    expect(libraryStandardTablePlayerName('Carlsen, Magnus'), 'Carlsen, M.');
  });

  test('a trailing initial stays the initial, never the surname', () {
    expect(libraryStandardTablePlayerName('Gukesh D'), 'Gukesh, D.');
    expect(
      libraryStandardTablePlayerName('Praggnanandhaa R'),
      'Praggnanandhaa, R.',
    );
    expect(libraryStandardTablePlayerName('Magnus Carlsen'), 'Carlsen, M.');
  });

  testWidgets('a result colour override replaces the board-colour palette', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LibraryTableResultPill(result: '0-1'),
              LibraryTableResultPill(result: '1-0', color: kWhiteColor70),
            ],
          ),
        ),
      ),
    );

    Color colorOf(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;
    expect(colorOf('0 – 1'), kRedColor);
    expect(colorOf('1 – 0'), kWhiteColor70);
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
