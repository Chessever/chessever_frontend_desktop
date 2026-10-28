import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Matches a key by its position on the keyboard plus exact modifiers.
///
/// Needed for Alt/Option chords: on macOS ⌥W types "∑", so the logical key
/// is no longer W and a [SingleActivator] would never match.
class PhysicalKeyActivator extends ShortcutActivator {
  const PhysicalKeyActivator(
    this.physicalKey, {
    this.alt = false,
    this.shift = false,
  });

  final PhysicalKeyboardKey physicalKey;
  final bool alt;
  final bool shift;

  @override
  Iterable<LogicalKeyboardKey>? get triggers => null;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    return event.physicalKey == physicalKey &&
        state.isAltPressed == alt &&
        state.isShiftPressed == shift &&
        !state.isMetaPressed &&
        !state.isControlPressed;
  }

  @override
  String debugDescribeKeys() =>
      '${alt ? 'Alt+' : ''}${shift ? 'Shift+' : ''}${physicalKey.debugName}';
}

/// Browsers keep tab and window chords for themselves (⌘/Ctrl+W, ⌘/Ctrl+T,
/// Ctrl+Tab, ⌘⇧[ ], ⌘⌥←/→, and Ctrl+N on Windows): the page never sees them,
/// and ⌘W would close ChessEver itself. The web build adds ⌥ alternatives
/// for the same tab actions.
Map<ShortcutActivator, Intent> browserSafeTabShortcuts({
  required Intent closeTab,
  required Intent newTab,
  required Intent nextTab,
  required Intent previousTab,
}) => {
  const PhysicalKeyActivator(PhysicalKeyboardKey.keyW, alt: true): closeTab,
  const PhysicalKeyActivator(PhysicalKeyboardKey.keyT, alt: true): newTab,
  const PhysicalKeyActivator(
    PhysicalKeyboardKey.bracketRight,
    alt: true,
    shift: true,
  ): nextTab,
  const PhysicalKeyActivator(
    PhysicalKeyboardKey.bracketLeft,
    alt: true,
    shift: true,
  ): previousTab,
};
