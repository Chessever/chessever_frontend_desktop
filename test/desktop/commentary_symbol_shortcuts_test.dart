import 'package:chessever/desktop/widgets/commentary_symbol_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('commentarySymbolForKey', () {
    test('maps reference piece shortcuts', () {
      expect(
        commentarySymbolForKey(
          LogicalKeyboardKey.keyK,
          ctrl: true,
          alt: false,
          shift: false,
        ),
        '♔',
      );
      expect(
        commentarySymbolForKey(
          LogicalKeyboardKey.keyQ,
          ctrl: true,
          alt: false,
          shift: false,
        ),
        '♕',
      );
      expect(
        commentarySymbolForKey(
          LogicalKeyboardKey.keyN,
          ctrl: true,
          alt: false,
          shift: false,
        ),
        '♘',
      );
    });

    test('maps reference evaluation and observation shortcuts', () {
      expect(
        commentarySymbolForKey(
          LogicalKeyboardKey.keyC,
          ctrl: true,
          alt: false,
          shift: true,
        ),
        '⇆',
      );
      expect(
        commentarySymbolForKey(
          LogicalKeyboardKey.keyI,
          ctrl: true,
          alt: true,
          shift: false,
        ),
        '∆',
      );
      expect(
        commentarySymbolForKey(
          LogicalKeyboardKey.digit2,
          ctrl: true,
          alt: false,
          shift: false,
        ),
        '±',
      );
      expect(
        commentarySymbolForKey(
          LogicalKeyboardKey.digit5,
          ctrl: true,
          alt: false,
          shift: false,
        ),
        '−+',
      );
    });
  });

  group('insertCommentarySymbol', () {
    test('replaces the current selection and keeps cursor after symbol', () {
      final controller = TextEditingController(text: 'better move');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 6,
      );

      insertCommentarySymbol(controller, '±');

      expect(controller.text, '± move');
      expect(controller.selection.baseOffset, 1);
    });
  });
}
