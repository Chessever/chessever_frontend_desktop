import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';

/// Card embedded in the desktop SettingsPane that lets the user remap
/// every [BoardActionKey]. State lives in [keyboardShortcutsProvider]
/// (sqflite-backed via [AppDatabase]) — this widget is purely presentation
/// and dispatch.
class KeyboardShortcutsSection extends ConsumerWidget {
  const KeyboardShortcutsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncMap = ref.watch(keyboardShortcutsProvider);

    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.keyboard_alt_outlined,
                  size: 16,
                  color: kPrimaryColor,
                ),
                const SizedBox(width: 10),
                const Text(
                  'Keyboard shortcuts',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _ResetAllButton(
                  onTap:
                      asyncMap.valueOrNull == null
                          ? null
                          : () =>
                              ref
                                  .read(keyboardShortcutsProvider.notifier)
                                  .resetAll(),
                ),
              ],
            ),
          ),
          const Divider(color: kDividerColor, height: 1),
          asyncMap.when(
            data:
                (map) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < BoardActionKey.values.length; i++) ...[
                      if (i > 0) const Divider(color: kDividerColor, height: 1),
                      _ShortcutRow(
                        action: BoardActionKey.values[i],
                        chords: map.chordsFor(BoardActionKey.values[i]),
                        bindings: map,
                      ),
                    ],
                  ],
                ),
            loading:
                () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                      ),
                    ),
                  ),
                ),
            error:
                (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Failed to load shortcuts: $e',
                    style: const TextStyle(color: kRedColor, fontSize: 12),
                  ),
                ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Text(
              'Click + to record a new keystroke. Click an existing chord '
              'to remove it. Settings persist locally.',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutRow extends ConsumerWidget {
  const _ShortcutRow({
    required this.action,
    required this.chords,
    required this.bindings,
  });

  final BoardActionKey action;
  final List<KeyChord> chords;
  final BoardShortcutMap bindings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(keyboardShortcutsProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  action.label,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  action.description,
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final chord in chords)
                  _ChordPill(
                    label: chord.label,
                    onRemove: () => notifier.removeChord(action, chord),
                  ),
                _AddChordButton(
                  onTap: () async {
                    final chord = await _showChordRecorder(
                      context,
                      action: action,
                      currentBindings: bindings,
                    );
                    if (chord == null) return;
                    await notifier.addChord(action, chord);
                  },
                ),
                if (_isOverridden(action, chords)) ...[
                  const SizedBox(width: 4),
                  _ResetActionButton(onTap: () => notifier.resetAction(action)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isOverridden(BoardActionKey action, List<KeyChord> chords) {
    final defaults = defaultBoardShortcuts()[action] ?? const <KeyChord>[];
    if (defaults.length != chords.length) return true;
    // Compare as sets — the user can reorder chords without that
    // counting as an override.
    final defaultSet = defaults.toSet();
    for (final chord in chords) {
      if (!defaultSet.contains(chord)) return true;
    }
    return false;
  }
}

class _ChordPill extends StatefulWidget {
  const _ChordPill({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  State<_ChordPill> createState() => _ChordPillState();
}

class _ChordPillState extends State<_ChordPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'Remove this binding',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onRemove,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color:
                    _hovered ? kRedColor.withValues(alpha: 0.18) : kBlack3Color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color:
                      _hovered
                          ? kRedColor.withValues(alpha: 0.6)
                          : kDividerColor,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: _hovered ? kRedColor : kWhiteColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (_hovered) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.close_rounded, size: 12, color: kRedColor),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddChordButton extends StatefulWidget {
  const _AddChordButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AddChordButton> createState() => _AddChordButtonState();
}

class _AddChordButtonState extends State<_AddChordButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'Record a new keystroke',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color:
                    _hovered
                        ? kPrimaryColor.withValues(alpha: 0.18)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color:
                      _hovered
                          ? kPrimaryColor.withValues(alpha: 0.6)
                          : kDividerColor,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 14, color: kPrimaryColor),
                  SizedBox(width: 4),
                  Text(
                    'Add',
                    style: TextStyle(
                      color: kPrimaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResetActionButton extends StatelessWidget {
  const _ResetActionButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'Restore the default binding',
      child: ClickCursor(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(
              Icons.refresh_rounded,
              size: 14,
              color: kLightGreyColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _ResetAllButton extends StatefulWidget {
  const _ResetAllButton({required this.onTap});
  final VoidCallback? onTap;

  @override
  State<_ResetAllButton> createState() => _ResetAllButtonState();
}

class _ResetAllButtonState extends State<_ResetAllButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return ClickCursor(
      enabled: !disabled,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: _hovered ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.restart_alt_rounded,
                  size: 14,
                  color: kLightGreyColor,
                ),
                SizedBox(width: 6),
                Text(
                  'Reset all',
                  style: TextStyle(
                    color: kLightGreyColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal that captures the next keystroke and returns the recorded
/// [KeyChord], or `null` if the user cancels. Surfaces conflict warnings
/// inline so the user knows when their chord steals from another action.
Future<KeyChord?> _showChordRecorder(
  BuildContext context, {
  required BoardActionKey action,
  required BoardShortcutMap currentBindings,
}) {
  return showDialog<KeyChord>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder:
        (ctx) => FTheme(
          data: FThemes.zinc.dark,
          child: _ChordRecorderDialog(
            action: action,
            currentBindings: currentBindings,
          ),
        ),
  );
}

class _ChordRecorderDialog extends StatefulWidget {
  const _ChordRecorderDialog({
    required this.action,
    required this.currentBindings,
  });

  final BoardActionKey action;
  final BoardShortcutMap currentBindings;

  @override
  State<_ChordRecorderDialog> createState() => _ChordRecorderDialogState();
}

class _ChordRecorderDialogState extends State<_ChordRecorderDialog> {
  final FocusNode _focus = FocusNode();
  KeyChord? _captured;
  BoardActionKey? _conflictWith;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Don't accept bare modifier keys — the chord would be empty.
    final key = event.logicalKey;
    if (_isModifier(key)) return KeyEventResult.ignored;

    // Esc cancels the recorder regardless of state.
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl =
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.control);
    final alt =
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight) ||
        pressed.contains(LogicalKeyboardKey.alt);
    final shift =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight) ||
        pressed.contains(LogicalKeyboardKey.shift);
    final meta =
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.meta);

    final chord = KeyChord(
      keyId: key.keyId,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
      meta: meta,
    );
    setState(() {
      _captured = chord;
      final existingAction = widget.currentBindings.actionForChord(chord);
      _conflictWith =
          (existingAction != null && existingAction != widget.action)
              ? existingAction
              : null;
    });
    return KeyEventResult.handled;
  }

  bool _isModifier(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.capsLock ||
        key == LogicalKeyboardKey.numLock;
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Container(
          width: 380,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Record shortcut for ${widget.action.label}',
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Press the keystroke you want to bind. Use Esc to cancel.',
                style: TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
              const SizedBox(height: 18),
              Container(
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kBlack3Color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        _captured == null
                            ? kDividerColor
                            : kPrimaryColor.withValues(alpha: 0.6),
                  ),
                ),
                child: Text(
                  _captured?.label ?? 'Listening…',
                  style: TextStyle(
                    color: _captured == null ? kLightGreyColor : kWhiteColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (_conflictWith != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFABE46).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFFFABE46).withValues(alpha: 0.6),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 14,
                        color: Color(0xFFFABE46),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Currently bound to "${_conflictWith!.label}". '
                          'Saving will leave both bindings in place — pick a '
                          'different chord if you want to keep them apart.',
                          style: const TextStyle(
                            color: Color(0xFFFABE46),
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    onPress: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label: 'Save',
                    tone: DesktopDialogButtonTone.primary,
                    onPress:
                        _captured == null
                            ? null
                            : () => Navigator.of(context).pop(_captured),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
