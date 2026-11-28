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
    // No comma and no single surname: shown as written, never turned
    // around (the same Library holds TWIC "Ding,L" as `Ding, L.`).
    expect(libraryStandardTablePlayerName('Magnus Carlsen'), 'Magnus Carlsen');
    expect(libraryStandardTablePlayerName('Ding Liren'), 'Ding Liren');
    expect(libraryStandardTablePlayerName('Ding,L'), 'Ding, L.');
  });

  test('study and repertoire labels are never abbreviated', () {
    for (final label in const [
      'Botvinnik / 10...Be7!? - 12.Bf6',
      'Botvinnik / 6.g3',
      'Very rare - Dynamic',
      'Rodriguez 1994',
      'Main Line (with note)',
      'Vaganian–Beliavsky 1985',
    ]) {
      expect(libraryPlayerNameIsPersonal(label), isFalse, reason: label);
      expect(libraryStandardTablePlayerName(label), label, reason: label);
    }
    expect(libraryPlayerNameIsPersonal('Main Line'), isTrue);
    expect(libraryPlayerNameIsPersonal('Carlsen, Magnus'), isTrue);
    expect(libraryPlayerNameIsPersonal('van der Wiel'), isTrue);
    expect(libraryPlayerNameIsPersonal("O'Sullivan"), isTrue);
  });

  testWidgets('a wide cell keeps the full name, a narrow one compacts', (
    tester,
  ) async {
    Widget row({required double width, required String name}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: LibraryTablePlayerCell(
              name: name,
              federation: 'NOR',
              title: '',
              rating: '2830',
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(row(width: 300, name: 'Carlsen, Magnus'));
    expect(find.text('Carlsen, Magnus'), findsOneWidget);
    expect(find.text('Carlsen, M.'), findsNothing);

    await tester.pumpWidget(row(width: 96, name: 'Carlsen, Magnus'));
    expect(find.text('Carlsen, M.'), findsOneWidget);

    // A name the rules cannot read is only ever ellipsized, never turned
    // around into `Carlsen, M.`.
    await tester.pumpWidget(row(width: 96, name: 'Magnus Carlsen'));
    expect(find.text('Magnus Carlsen'), findsOneWidget);
    expect(find.text('Carlsen, M.'), findsNothing);

    // A study label is never rewritten, however tight the column is.
    await tester.pumpWidget(
      row(width: 96, name: 'Botvinnik / 10...Be7!? - 12.Bf6'),
    );
    expect(find.text('Botvinnik / 10...Be7!? - 12.Bf6'), findsOneWidget);
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
