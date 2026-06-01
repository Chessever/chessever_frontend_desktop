import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';

void main() {
  group('library save dialog copy', () {
    test('labels saved payloads as entries for games and positions', () {
      expect(librarySaveEntryLabel(1), 'entry');
      expect(librarySaveEntryLabel(2), 'entries');
      expect(librarySaveEntryLabel(0), 'entries');
    });

    test('reports update-original outcome as a save', () {
      const outcome = LibrarySaveOutcome(
        savedRows: 0,
        folderCount: 0,
        didUpdateOriginal: true,
      );

      expect(outcome.didSave, isTrue);
      expect(outcome.toToastMessage(), 'Updated existing game');
    });
  });

  group('splitPlayerName', () {
    test('splits surname-first PGN names on the comma', () {
      final parts = splitPlayerName('Kasparov, Garry');
      expect(parts.surname, 'Kasparov');
      expect(parts.firstName, 'Garry');
    });

    test('treats single-token names as surname only', () {
      final parts = splitPlayerName('Magnus');
      expect(parts.surname, 'Magnus');
      expect(parts.firstName, '');
    });

    test('coerces empty and placeholder values to empty parts', () {
      expect(splitPlayerName(null).surname, '');
      expect(splitPlayerName(null).firstName, '');
      expect(splitPlayerName('').surname, '');
      expect(splitPlayerName('?').surname, '');
    });
  });

  group('joinPlayerName', () {
    test('combines surname and first name with a comma', () {
      expect(joinPlayerName('Carlsen', 'Magnus'), 'Carlsen, Magnus');
    });

    test('returns a single component when the other is empty', () {
      expect(joinPlayerName('Carlsen', ''), 'Carlsen');
      expect(joinPlayerName('', 'Magnus'), 'Magnus');
    });

    test('falls back to "?" when both halves are blank', () {
      expect(joinPlayerName('', ''), '?');
      expect(joinPlayerName('   ', '\t'), '?');
    });
  });

  group('buildPgnDate', () {
    test('returns fully-unknown date when year is blank', () {
      expect(buildPgnDate(year: '', month: '5', day: '12'), '????.??.??');
    });

    test('pads month and day to two digits', () {
      expect(
        buildPgnDate(year: '2026', month: '5', day: '7'),
        '2026.05.07',
      );
    });

    test('substitutes ?? for missing month or day', () {
      expect(buildPgnDate(year: '2026', month: '', day: ''), '2026.??.??');
      expect(buildPgnDate(year: '2026', month: '11', day: ''), '2026.11.??');
    });
  });

  group('buildEditedMetadata', () {
    test('overwrites editable PGN headers while preserving unrelated keys', () {
      final original = <String, dynamic>{
        'White': 'Old, Player',
        'Black': 'Other, Player',
        'Event': 'Old Event',
        'ECO': 'A00',
        'Result': '*',
        'WhiteElo': '2000',
        'BlackElo': '2100',
        'Round': '1',
        'Subround': '',
        'Date': '2020.01.01',
        'isLiveGame': false,
        'TimeControl': '90+30',
      };

      final merged = buildEditedMetadata(
        original: original,
        whiteSurname: 'Carlsen',
        whiteFirstName: 'Magnus',
        blackSurname: 'Caruana',
        blackFirstName: 'Fabiano',
        event: 'Norway Chess',
        eco: 'C50',
        whiteElo: '2839',
        blackElo: '2805',
        round: '7',
        subround: '1',
        result: '1-0',
        year: '2026',
        month: '5',
        day: '24',
      );

      expect(merged['White'], 'Carlsen, Magnus');
      expect(merged['Black'], 'Caruana, Fabiano');
      expect(merged['Event'], 'Norway Chess');
      expect(merged['ECO'], 'C50');
      expect(merged['WhiteElo'], '2839');
      expect(merged['BlackElo'], '2805');
      expect(merged['Round'], '7');
      expect(merged['Subround'], '1');
      expect(merged['Result'], '1-0');
      expect(merged['Date'], '2026.05.24');
      // Headers outside the editor's scope must stay intact.
      expect(merged['isLiveGame'], false);
      expect(merged['TimeControl'], '90+30');
    });

    test('clamps unsupported result codes back to "*"', () {
      final merged = buildEditedMetadata(
        original: const {},
        whiteSurname: 'A',
        whiteFirstName: '',
        blackSurname: 'B',
        blackFirstName: '',
        event: 'E',
        eco: '',
        whiteElo: '',
        blackElo: '',
        round: '1',
        subround: '',
        result: 'banana',
        year: '',
        month: '',
        day: '',
      );
      expect(merged['Result'], '*');
    });

    test('substitutes "?" for empty White/Black/Event/Round so PGN stays valid',
        () {
      final merged = buildEditedMetadata(
        original: const {},
        whiteSurname: '',
        whiteFirstName: '',
        blackSurname: '',
        blackFirstName: '',
        event: '',
        eco: '',
        whiteElo: '',
        blackElo: '',
        round: '',
        subround: '',
        result: '*',
        year: '',
        month: '',
        day: '',
      );
      expect(merged['White'], '?');
      expect(merged['Black'], '?');
      expect(merged['Event'], '?');
      expect(merged['Round'], '?');
      expect(merged['Date'], '????.??.??');
    });
  });
}
