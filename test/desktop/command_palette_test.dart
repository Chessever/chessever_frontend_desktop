import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/command_palette.dart';

void main() {
  test('command palette exposes local chess browsing actions', () {
    expect(
      debugCommandPaletteEntryTitles(),
      containsAll(<String>[
        'Open PGN on Board…',
        'Browse Local Chess Folder…',
        'Open Local Chess Files…',
      ]),
    );

    expect(
      debugCommandPaletteActionForTitle('Browse Local Chess Folder…'),
      CommandAction.openLocalChessFolder,
    );
    expect(
      debugCommandPaletteActionForTitle('Open Local Chess Files…'),
      CommandAction.openLocalChessFiles,
    );
    expect(
      debugCommandPaletteEntryTitles(),
      isNot(contains('Open Opening Explorer')),
    );
  });
  test('command palette arrow navigation wraps one row at a time', () {
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
  });

  test('command palette page navigation jumps by a larger clamped step', () {
    expect(
      pageCommandPaletteHighlight(current: null, itemCount: 20, direction: 1),
      3,
    );
    expect(
      pageCommandPaletteHighlight(current: null, itemCount: 20, direction: -1),
      16,
    );
    expect(
      pageCommandPaletteHighlight(current: 3, itemCount: 20, direction: 1),
      7,
    );
    expect(
      pageCommandPaletteHighlight(current: 3, itemCount: 20, direction: -1),
      0,
    );
    expect(
      pageCommandPaletteHighlight(current: 18, itemCount: 20, direction: 1),
      19,
    );
    expect(
      pageCommandPaletteHighlight(current: null, itemCount: 0, direction: 1),
      isNull,
    );
  });
}
