import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Yields a shortcut to the platform text input system while text is edited.
///
/// Board bindings include unmodified letters, punctuation, and navigation
/// keys. They must be inert whenever an [EditableText] owns primary focus.
class EditableAwareShortcutActivator extends ShortcutActivator {
  const EditableAwareShortcutActivator(this.delegate);

  final ShortcutActivator delegate;

  @override
  Iterable<LogicalKeyboardKey>? get triggers => delegate.triggers;

  @override
  String debugDescribeKeys() => delegate.debugDescribeKeys();

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    return !focusIsEditingText(FocusManager.instance.primaryFocus) &&
        delegate.accepts(event, state);
  }
}

/// Guards every shortcut in [shortcuts] while an [EditableText] owns focus.
///
/// [allowedWhileEditing] is reserved for truly global commands that must stay
/// reachable from text fields, such as the shell's global search shortcut.
Map<ShortcutActivator, Intent> editableAwareShortcuts(
  Map<ShortcutActivator, Intent> shortcuts, {
  bool Function(ShortcutActivator activator)? allowedWhileEditing,
}) {
  return <ShortcutActivator, Intent>{
    for (final entry in shortcuts.entries)
      if (entry.key is EditableAwareShortcutActivator ||
          (allowedWhileEditing?.call(entry.key) ?? false))
        entry.key: entry.value
      else
        EditableAwareShortcutActivator(entry.key): entry.value,
  };
}

bool focusIsEditingText(FocusNode? focus) {
  final context = focus?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorStateOfType<EditableTextState>() != null;
}
