import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/board_pgn_paste.dart';
import 'package:chessever/desktop/state/board_tab_sound_mute.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveBoardPgnPasteMode', () {
    test(
      'inserts clipboard PGN when the active board already has notation',
      () {
        expect(
          resolveBoardPgnPasteMode(activeBoardHasNotation: true),
          BoardPgnPasteMode.insertIntoCurrentNotation,
        );
      },
    );

    test(
      'loads clipboard PGN into the active board when notation is empty',
      () {
        expect(
          resolveBoardPgnPasteMode(activeBoardHasNotation: false),
          BoardPgnPasteMode.loadIntoCurrentBoard,
        );
      },
    );
  });

  group('shouldPlaySoundForBoardMove', () {
    test('allows normal board moves when the sound gate allows them', () {
      expect(shouldPlaySoundForBoardMove(soundGateAllows: true), isTrue);
    });

    test('keeps bulk notation paste and insert silent', () {
      expect(
        shouldPlaySoundForBoardMove(soundGateAllows: true, suppressSound: true),
        isFalse,
      );
    });

    test('respects the existing mute/settings gate', () {
      expect(shouldPlaySoundForBoardMove(soundGateAllows: false), isFalse);
    });
  });

  group('shouldPlayTabSound', () {
    test('plays for the tab the user is looking at', () {
      expect(
        shouldPlayTabSound(
          tabId: 'board-1',
          activeTabId: 'board-1',
          globallyEnabled: true,
        ),
        isTrue,
      );
    });

    test('stays silent for a background board tab', () {
      // The Events feed is active; a hidden live board keeps streaming and
      // must not announce moves.
      expect(
        shouldPlayTabSound(
          tabId: 'board-1',
          activeTabId: 'tournaments-default',
          globallyEnabled: true,
        ),
        isFalse,
      );
    });

    test('respects the global sound preference and per-tab mute', () {
      expect(
        shouldPlayTabSound(
          tabId: 'board-1',
          activeTabId: 'board-1',
          globallyEnabled: false,
        ),
        isFalse,
      );
      expect(
        shouldPlayTabSound(
          tabId: 'board-1',
          activeTabId: 'board-1',
          globallyEnabled: true,
          tabMuted: true,
        ),
        isFalse,
      );
    });

    test('keeps standalone boards (no tab id) audible', () {
      expect(
        shouldPlayTabSound(
          tabId: null,
          activeTabId: 'tournaments-default',
          globallyEnabled: true,
        ),
        isTrue,
      );
      expect(
        shouldPlayTabSound(
          tabId: '  ',
          activeTabId: null,
          globallyEnabled: true,
        ),
        isTrue,
      );
    });
  });

  group('clipboardPgnSourceLabel', () {
    test('builds a compact label from PGN headers', () {
      const pgn = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2024.01.15"]
[White "Magnus Carlsen"]
[Black "Nepomniachtchi, Ian"]
[WhiteElo "2830"]
[BlackElo "2769"]
[Result "1-0"]

1. e4 e5 1-0
''';

      expect(
        clipboardPgnSourceLabel(pgn),
        '1-0 Carlsen,M (2830)-Nepomniachtchi,I (2769) Wijk aan Zee 2024',
      );
    });

    test('falls back for invalid clipboard text', () {
      expect(clipboardPgnSourceLabel('not a pgn'), 'Clipboard PGN');
    });
  });
}
