import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
        shortcuts[BoardActionKey.openExplorer],
        contains(KeyChord(keyId: LogicalKeyboardKey.enter.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.openExplorer],
        contains(KeyChord(keyId: LogicalKeyboardKey.numpadEnter.keyId)),
      );
      expect(
        shortcuts[BoardActionKey.firstMove],
        contains(
          KeyChord(keyId: LogicalKeyboardKey.arrowLeft.keyId, ctrl: true),
        ),
      );
      expect(
        shortcuts[BoardActionKey.firstMove],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.arrowLeft.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        shortcuts[BoardActionKey.lastMove],
        contains(
          KeyChord(keyId: LogicalKeyboardKey.arrowRight.keyId, ctrl: true),
        ),
      );
      expect(
        shortcuts[BoardActionKey.lastMove],
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.arrowRight.keyId,
            meta: true,
            crossPlatform: true,
          ),
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
        contains(KeyChord(keyId: LogicalKeyboardKey.equal.keyId, shift: true)),
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
      expect(shortcuts[BoardActionKey.rightRailActivateSelection], isEmpty);
    });
    test('prev/next game defaults resolve on macOS, Windows, and Linux', () {
      final shortcuts = defaultBoardShortcuts();
      final prev = shortcuts[BoardActionKey.prevGame]!;
      final next = shortcuts[BoardActionKey.nextGame]!;

      // Shipped chords: primary-modifier + arrows (cross-platform) plus
      // F10 alternates used by reference UIs.
      expect(
        prev,
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.arrowUp.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(
        prev,
        contains(KeyChord(keyId: LogicalKeyboardKey.f10.keyId, ctrl: true)),
      );
      expect(
        next,
        contains(
          KeyChord(
            keyId: LogicalKeyboardKey.arrowDown.keyId,
            meta: true,
            crossPlatform: true,
          ),
        ),
      );
      expect(next, contains(KeyChord(keyId: LogicalKeyboardKey.f10.keyId)));
      expect(next, contains(KeyChord(keyId: LogicalKeyboardKey.f11.keyId)));

      final prevPrimary = prev.firstWhere(
        (c) => c.keyId == LogicalKeyboardKey.arrowUp.keyId && c.crossPlatform,
      );
      final nextPrimary = next.firstWhere(
        (c) => c.keyId == LogicalKeyboardKey.arrowDown.keyId && c.crossPlatform,
      );

      // macOS: Cmd+↑ / Cmd+↓
      expect(prevPrimary.resolvedModifiers(isMacOS: true), (ctrl: false, meta: true));
      expect(nextPrimary.resolvedModifiers(isMacOS: true), (ctrl: false, meta: true));
      // Windows + Linux: Ctrl+↑ / Ctrl+↓
      expect(
        prevPrimary.resolvedModifiers(isMacOS: false),
        (ctrl: true, meta: false),
      );
      expect(
        nextPrimary.resolvedModifiers(isMacOS: false),
        (ctrl: true, meta: false),
      );

      // Dual registration: both platform forms must land in the Shortcuts map
      // so a Mac user pressing Ctrl or a Windows user with a shared keymap
      // still reaches navigateActiveEventGame.
      final prevActivators = prevPrimary.toAllPlatformActivators();
      final nextActivators = nextPrimary.toAllPlatformActivators();
      expect(prevActivators, hasLength(2));
      expect(nextActivators, hasLength(2));

      SingleActivator asSingle(ShortcutActivator a) => a as SingleActivator;
      final prevForms = prevActivators.map(asSingle).toList();
      final nextForms = nextActivators.map(asSingle).toList();
      expect(
        prevForms.any((a) => a.meta && !a.control && a.trigger == LogicalKeyboardKey.arrowUp),
        isTrue,
      );
      expect(
        prevForms.any((a) => a.control && !a.meta && a.trigger == LogicalKeyboardKey.arrowUp),
        isTrue,
      );
      expect(
        nextForms.any((a) => a.meta && !a.control && a.trigger == LogicalKeyboardKey.arrowDown),
        isTrue,
      );
      expect(
        nextForms.any((a) => a.control && !a.meta && a.trigger == LogicalKeyboardKey.arrowDown),
        isTrue,
      );

      // Manual key-handler path (notation panel) accepts either primary form.
      expect(
        prevPrimary.matchesPressedModifiers(
          ctrl: false,
          meta: true,
          alt: false,
          shift: false,
          isMacOS: true,
        ),
        isTrue,
      );
      expect(
        prevPrimary.matchesPressedModifiers(
          ctrl: true,
          meta: false,
          alt: false,
          shift: false,
          isMacOS: false,
        ),
        isTrue,
      );
      expect(
        nextPrimary.matchesPressedModifiers(
          ctrl: true,
          meta: false,
          alt: false,
          shift: false,
        ),
        isTrue,
      );
      // Bare arrows must not steal prev/next game (those are move/line nav).
      expect(
        prevPrimary.matchesPressedModifiers(
          ctrl: false,
          meta: false,
          alt: false,
          shift: false,
        ),
        isFalse,
      );

      // F10 alternates are platform-literal (same on every host).
      final prevF10 = prev.firstWhere(
        (c) => c.keyId == LogicalKeyboardKey.f10.keyId,
      );
      final nextF10 = next.firstWhere(
        (c) => c.keyId == LogicalKeyboardKey.f10.keyId && !c.ctrl,
      );
      expect(prevF10.toAllPlatformActivators(), hasLength(1));
      expect(nextF10.toAllPlatformActivators(), hasLength(1));
      expect(
        prevF10.resolvedModifiers(isMacOS: true),
        (ctrl: true, meta: false),
      );
      expect(
        prevF10.resolvedModifiers(isMacOS: false),
        (ctrl: true, meta: false),
      );
      expect(
        (nextF10.toActivator(isMacOS: true) as SingleActivator).trigger,
        LogicalKeyboardKey.f10,
      );
      expect(
        (nextF10.toActivator(isMacOS: false) as SingleActivator).control,
        isFalse,
      );

      // Tooltip labels follow the host primary-modifier convention.
      final macPrevLabel = prevPrimary.labelFor(isMacOS: true);
      final winPrevLabel = prevPrimary.labelFor(isMacOS: false);
      final winNextLabel = nextPrimary.labelFor(isMacOS: false);
      expect(macPrevLabel, contains('⌘'));
      expect(winPrevLabel, startsWith('Ctrl'));
      expect(winNextLabel, startsWith('Ctrl'));
      expect(macPrevLabel.toLowerCase(), anyOf(contains('↑'), contains('up')));
      expect(winNextLabel.toLowerCase(), anyOf(contains('↓'), contains('down')));
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
