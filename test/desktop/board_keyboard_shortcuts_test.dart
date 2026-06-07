import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';

void main() {
  group('defaultBoardShortcuts', () {
    test('matches requested PGN and board action shortcuts', () {
      final shortcuts = defaultBoardShortcuts();

      expect(
        shortcuts[BoardActionKey.copyPgn],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.keyC.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.pastePgn],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.keyV.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.savePgnFile],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.keyS.keyId,
            meta: true,
            shift: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.saveGameToLibrary],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.keyS.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.commentAfterMove],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.keyA.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.flipBoard],
        contains(KeyChord(keyId: LogicalKeyboardKey.keyF.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.flipBoard],
        isNot(
          contains(
            KeyChord(
              keyId: LogicalKeyboardKey.keyF.keyId,
              meta: true,
              crossPlatform: true,
            ),
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.flipBoard],
        isNot(
          contains(KeyChord(keyId: LogicalKeyboardKey.keyF.keyId, ctrl: true)),
        ),
      );
      expect(
        shortcuts[BoardActionKey.toggleBoardFocus],
        contains(KeyChord(keyId: LogicalKeyboardKey.keyB.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.flipBoard],
        isNot(contains(KeyChord(keyId: LogicalKeyboardKey.keyB.keyId))),
      );
      expect(
        shortcuts[BoardActionKey.playEngineMove],
        contains(KeyChord(keyId: LogicalKeyboardKey.space.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.previousNotationLine],
        contains(KeyChord(keyId: LogicalKeyboardKey.arrowUp.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.nextNotationLine],
        contains(KeyChord(keyId: LogicalKeyboardKey.arrowDown.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.firstMove],
        contains(
          KeyChord(keyId: LogicalKeyboardKey.arrowLeft.keyId, ctrl: true),
        ),
      );
      expect(
        shortcuts[BoardActionKey.lastMove],
        contains(
          KeyChord(keyId: LogicalKeyboardKey.arrowRight.keyId, ctrl: true),
        ),
      );
      expect(
        shortcuts[BoardActionKey.firstMove],
        isNot(contains(KeyChord(keyId: LogicalKeyboardKey.arrowUp.keyId))),
      );
      expect(
        shortcuts[BoardActionKey.firstMove],
        isNot(
          contains(
            KeyChord(keyId: LogicalKeyboardKey.arrowLeft.keyId, shift: true),
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.lastMove],
        isNot(contains(KeyChord(keyId: LogicalKeyboardKey.arrowDown.keyId))),
      );
      expect(
        shortcuts[BoardActionKey.lastMove],
        isNot(
          contains(
            KeyChord(keyId: LogicalKeyboardKey.arrowRight.keyId, shift: true),
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.undoLastEdit],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.keyZ.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.undoLastEdit],
        contains(KeyChord(keyId: LogicalKeyboardKey.keyZ.keyId, ctrl: true)),
      );
    });

    test('covers reference board-window shortcut defaults', () {
      final shortcuts = defaultBoardShortcuts();

      expect(
        shortcuts[BoardActionKey.flipBoard],
        contains(KeyChord(keyId: LogicalKeyboardKey.keyF.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.autoReplay],
        contains(KeyChord(keyId: LogicalKeyboardKey.asterisk.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.goToMoveNumber],
        contains(KeyChord(keyId: LogicalKeyboardKey.keyG.keyId, ctrl: true)),
      );
      expect(
        shortcuts[BoardActionKey.deleteVariation],
        contains(KeyChord(keyId: LogicalKeyboardKey.keyY.keyId, ctrl: true)),
      );
      expect(
        shortcuts[BoardActionKey.increaseEngineLines],
        contains(KeyChord(keyId: LogicalKeyboardKey.add.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.decreaseEngineLines],
        contains(KeyChord(keyId: LogicalKeyboardKey.minus.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.cutRemainingMoves],
        contains(KeyChord(keyId: LogicalKeyboardKey.bracketRight.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.clearVariationsAndComments],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.keyY.keyId,
            ctrl: true,
            shift: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.deleteGraphicCommentary],
        contains(
          KeyChord(keyId: LogicalKeyboardKey.keyY.keyId, ctrl: true, alt: true),
        ),
      );
      expect(
        shortcuts[BoardActionKey.nextGame],
        contains(KeyChord(keyId: LogicalKeyboardKey.f10.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.prevGame],
        contains(KeyChord(keyId: LogicalKeyboardKey.f10.keyId, ctrl: true)),
      );
      expect(
        shortcuts[BoardActionKey.rightRailPreviousTab],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.comma.keyId,
            meta: true,
            shift: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.rightRailPreviousTab],
        isNot(
          contains(
            KeyChord(
              keyId: LogicalKeyboardKey.arrowLeft.keyId,
              meta: true,
              crossPlatform: true,
            ),
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.rightRailNextTab],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.period.keyId,
            meta: true,
            shift: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.rightRailNextTab],
        isNot(
          contains(
            KeyChord(
              keyId: LogicalKeyboardKey.arrowRight.keyId,
              meta: true,
              crossPlatform: true,
            ),
          ),
        ),
      );
      // Shift+←/→ is no longer a customizable right-rail shortcut; the
      // Explorer surface owns that chord locally for Moves ⇄ Games focus.
      expect(shortcuts[BoardActionKey.rightRailPreviousTable], isEmpty);
      expect(shortcuts[BoardActionKey.rightRailNextTable], isEmpty);
      expect(
        shortcuts[BoardActionKey.rightRailPreviousTab],
        contains(
          KeyChord(keyId: LogicalKeyboardKey.arrowLeft.keyId, alt: true),
        ),
      );
      expect(
        shortcuts[BoardActionKey.rightRailNextTab],
        contains(
          KeyChord(keyId: LogicalKeyboardKey.arrowRight.keyId, alt: true),
        ),
      );
      expect(
        shortcuts[BoardActionKey.rightRailActivateSelection],
        contains(KeyChord(keyId: LogicalKeyboardKey.enter.keyId)),
      );
    });
    test('reserves Ctrl/Cmd+F for search instead of board flip', () {
      final ctrlF = KeyChord(keyId: LogicalKeyboardKey.keyF.keyId, ctrl: true);
      final cmdF = KeyChord(keyId: LogicalKeyboardKey.keyF.keyId, meta: true);
      final primaryF = KeyChord(
        keyId: LogicalKeyboardKey.keyF.keyId,
        meta: true,
        crossPlatform: true,
      );

      final map = BoardShortcutMap({
        BoardActionKey.flipBoard: [
          KeyChord(keyId: LogicalKeyboardKey.keyF.keyId),
          ctrlF,
          cmdF,
          primaryF,
        ],
      });

      expect(map.chordsFor(BoardActionKey.flipBoard), [
        KeyChord(keyId: LogicalKeyboardKey.keyF.keyId),
      ]);
      expect(map.actionForChord(ctrlF), isNull);
      expect(map.actionForChord(cmdF), isNull);
      expect(map.actionForChord(primaryF), isNull);
      expect(
        map.actionForChord(KeyChord(keyId: LogicalKeyboardKey.keyF.keyId)),
        BoardActionKey.flipBoard,
      );
    });
  });
}
