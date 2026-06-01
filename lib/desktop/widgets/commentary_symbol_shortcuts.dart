import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// reference-compatible commentary-symbol shortcuts for desktop text editors.
///
/// Some legacy desktop databases render many of these through its own fonts. We insert Unicode
/// fallbacks so comments remain portable PGN text on macOS and Windows.
class CommentarySymbolShortcuts extends StatelessWidget {
  const CommentarySymbolShortcuts({
    super.key,
    required this.controller,
    required this.child,
  });

  final TextEditingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(onKeyEvent: _handleKey, child: child);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final symbol = commentarySymbolForKey(
      event.logicalKey,
      ctrl:
          pressed.contains(LogicalKeyboardKey.controlLeft) ||
          pressed.contains(LogicalKeyboardKey.controlRight) ||
          pressed.contains(LogicalKeyboardKey.control),
      alt:
          pressed.contains(LogicalKeyboardKey.altLeft) ||
          pressed.contains(LogicalKeyboardKey.altRight) ||
          pressed.contains(LogicalKeyboardKey.alt),
      shift:
          pressed.contains(LogicalKeyboardKey.shiftLeft) ||
          pressed.contains(LogicalKeyboardKey.shiftRight) ||
          pressed.contains(LogicalKeyboardKey.shift),
    );
    if (symbol == null) return KeyEventResult.ignored;
    insertCommentarySymbol(controller, symbol);
    return KeyEventResult.handled;
  }
}

@visibleForTesting
String? commentarySymbolForKey(
  LogicalKeyboardKey key, {
  required bool ctrl,
  required bool alt,
  required bool shift,
}) {
  if (!ctrl) return null;
  final id = key.keyId;

  if (alt && shift) return null;

  if (alt) {
    if (id == LogicalKeyboardKey.keyI.keyId) return '∆';
    if (id == LogicalKeyboardKey.keyD.keyId) return '↗';
    if (id == LogicalKeyboardKey.keyZ.keyId) return '⨀';
    if (id == LogicalKeyboardKey.keyC.keyId) return '⊕';
    if (id == LogicalKeyboardKey.keyW.keyId) return 'w/o';
    if (id == LogicalKeyboardKey.keyQ.keyId) return 'QS';
    if (id == LogicalKeyboardKey.keyK.keyId) return 'KS';
    if (id == LogicalKeyboardKey.keyP.keyId) return '♗♗';
    if (id == LogicalKeyboardKey.keyO.keyId) return '♗≠♝';
    if (id == LogicalKeyboardKey.keyE.keyId) return '♗=♝';
    if (id == LogicalKeyboardKey.keyB.keyId) return '⌓';
    if (id == LogicalKeyboardKey.keyR.keyId) return '=';
    return null;
  }

  if (shift) {
    if (id == LogicalKeyboardKey.keyC.keyId) return '⇆';
    if (id == LogicalKeyboardKey.keyZ.keyId) return '⏱';
    if (id == LogicalKeyboardKey.keyD.keyId) return '⟋';
    if (id == LogicalKeyboardKey.keyW.keyId) return '◇';
    if (id == LogicalKeyboardKey.keyP.keyId) return '♙↑';
    return null;
  }

  if (id == LogicalKeyboardKey.keyK.keyId) return '♔';
  if (id == LogicalKeyboardKey.keyQ.keyId) return '♕';
  if (id == LogicalKeyboardKey.keyN.keyId) return '♘';
  if (id == LogicalKeyboardKey.keyB.keyId) return '♗';
  if (id == LogicalKeyboardKey.keyR.keyId) return '♖';
  if (id == LogicalKeyboardKey.keyP.keyId) return '♙';
  if (id == LogicalKeyboardKey.keyA.keyId) return '→';
  if (id == LogicalKeyboardKey.keyI.keyId) return '↑';
  if (id == LogicalKeyboardKey.keyS.keyId) return '□';
  if (id == LogicalKeyboardKey.keyL.keyId) return '↔';
  if (id == LogicalKeyboardKey.keyO.keyId) return '□';
  if (id == LogicalKeyboardKey.keyW.keyId) return 'w/';
  if (id == LogicalKeyboardKey.keyE.keyId) return 'EG';
  if (id == LogicalKeyboardKey.keyM.keyId) return '∞';
  if (id == LogicalKeyboardKey.digit1.keyId) return '+−';
  if (id == LogicalKeyboardKey.digit2.keyId) return '±';
  if (id == LogicalKeyboardKey.digit3.keyId) return '∞';
  if (id == LogicalKeyboardKey.digit4.keyId) return '∓';
  if (id == LogicalKeyboardKey.digit5.keyId) return '−+';
  return null;
}

@visibleForTesting
void insertCommentarySymbol(TextEditingController controller, String symbol) {
  final value = controller.value;
  final text = value.text;
  final selection = value.selection;
  final start = selection.isValid ? selection.start : text.length;
  final end = selection.isValid ? selection.end : text.length;
  final lower = start < end ? start : end;
  final upper = start < end ? end : start;
  final nextText = text.replaceRange(lower, upper, symbol);
  final offset = lower + symbol.length;
  controller.value = value.copyWith(
    text: nextText,
    selection: TextSelection.collapsed(offset: offset),
    composing: TextRange.empty,
  );
}
