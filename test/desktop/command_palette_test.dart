import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/command_palette.dart';

void main() {
  test('command palette routes local intake through PGN import only', () {
    expect(
      debugCommandPaletteEntryTitles(),
      containsAll(<String>['Open PGN on Board…', 'Import PGN in Library…']),
    );

    expect(
      debugCommandPaletteEntryTitles(),
      isNot(contains('Browse Local Chess Folder…')),
    );
    expect(
      debugCommandPaletteEntryTitles(),
      isNot(contains('Open Local Chess Files…')),
    );
    expect(
      debugCommandPaletteActionForTitle('Import PGN in Library…'),
      CommandAction.openLocalChessFiles,
    );
    expect(
      debugCommandPaletteEntryTitles(),
      isNot(contains('Open Opening Explorer')),
    );
  });
  test(
    'command palette starts with no highlighted result until arrows move',
    () {
      expect(
        nextCommandPaletteHighlight(current: null, itemCount: 5, direction: 1),
        0,
      );
      expect(
        nextCommandPaletteHighlight(current: null, itemCount: 5, direction: -1),
        4,
      );
      expect(
        nextCommandPaletteHighlight(current: 0, itemCount: 5, direction: -1),
        4,
      );
      expect(
        nextCommandPaletteHighlight(current: 4, itemCount: 5, direction: 1),
        0,
      );
      expect(
        nextCommandPaletteHighlight(current: null, itemCount: 0, direction: 1),
        isNull,
      );
    },
  );
}
