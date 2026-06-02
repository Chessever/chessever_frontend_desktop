import 'package:flutter/services.dart';

/// True while the platform's "open link in new tab" modifier is held.
///
/// Chrome uses Command on macOS and Control on Windows/Linux. We accept both
/// so external keyboards and tests don't need platform branches.
bool isNewTabModifierPressed() {
  final pressed = HardwareKeyboard.instance.logicalKeysPressed;
  return pressed.contains(LogicalKeyboardKey.meta) ||
      pressed.contains(LogicalKeyboardKey.metaLeft) ||
      pressed.contains(LogicalKeyboardKey.metaRight) ||
      pressed.contains(LogicalKeyboardKey.control) ||
      pressed.contains(LogicalKeyboardKey.controlLeft) ||
      pressed.contains(LogicalKeyboardKey.controlRight);
}
