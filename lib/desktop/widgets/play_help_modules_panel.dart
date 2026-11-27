import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/state/toby_enabled.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/play_help_trigger.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/desktop/services/engine/stockfish_version.dart';

/// One switch per help module, plus where the board's arrows come from.
/// The setup screen and the in-game section show the same list, bound to
/// the same saved choice ([playHelpModulesProvider]).
class PlayHelpModulesList extends ConsumerWidget {
  const PlayHelpModulesList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modules = ref.watch(playHelpModulesProvider);
    final notifier = ref.read(playHelpModulesProvider.notifier);
    // Toby off (the account's switch): none of his help is offered.
    final tobyOn = ref.watch(tobyEnabledProvider);
    // Keys only act in the Peek and Hints styles. In Always on the keycaps
    // stay in place, dimmed and still editable, so the rows never shift
    // when the style changes and keys can be set up ahead of time.
    final keysLive =
        ref.watch(playHelpStyleProvider.select((s) => s.level)) !=
        PlayHelpLevel.always;
    Widget row(
      PlayHelpModule module,
      String description,
      bool value,
      PlayHelpModules Function(bool on) change,
    ) => _ModuleRow(
      module: module,
      description: description,
      value: value,
      keysLive: keysLive,
      onChange: (on) => notifier.set(change(on)),
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // How the help below reaches the player, chosen first, like a
          // game's difficulty.
          const PlayHelpStylePicker(),
          const SizedBox(height: 6),
          PlayHelpKeyBinding(
            target: null,
            live: keysLive,
            leading: const _RowText(
              label: 'All help',
              description: 'One key for everything switched on.',
            ),
          ),
          const SizedBox(height: 8),
          row(
            PlayHelpModule.engineLines,
            'Stockfish’s best lines beside the moves.',
            modules.engineLines,
            (on) => modules.copyWith(engineLines: on),
          ),
          row(
            PlayHelpModule.evalBar,
            'Stockfish’s evaluation left of the board.',
            modules.evalBar,
            (on) => modules.copyWith(evalBar: on),
          ),
          if (tobyOn) ...[
            row(
              PlayHelpModule.tobyPredictions,
              'The moves Toby expects players like you to choose.',
              modules.tobyPredictions,
              (on) => modules.copyWith(tobyPredictions: on),
            ),
            row(
              PlayHelpModule.tobyBar,
              'Toby’s win, draw and loss chances right of the board.',
              modules.tobyBar,
              (on) => modules.copyWith(tobyBar: on),
            ),
          ],
          row(
            PlayHelpModule.moveMarks,
            'Book, !!, ?? and the rest on each move as it is played.',
            modules.moveMarks,
            (on) => modules.copyWith(moveMarks: on),
          ),
          row(
            PlayHelpModule.explorer,
            'Games that reached the position, and what was played.',
            modules.explorer,
            (on) => modules.copyWith(explorer: on),
          ),
          row(
            PlayHelpModule.arrowEvals,
            'The engine’s eval on legal arrows you right-drag.',
            modules.arrowEvals,
            (on) => modules.copyWith(arrowEvals: on),
          ),
          const SizedBox(height: 8),
          PlayHelpKeyBinding(
            target: PlayHelpModule.arrows,
            live: keysLive,
            leading: const Text(
              'Board arrows',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 4),
          DesktopSegmentedTabs<PlayHelpArrows>(
            tabs: [
              const DesktopSegmentedTab(
                value: PlayHelpArrows.off,
                label: 'Off',
              ),
              const DesktopSegmentedTab(
                value: PlayHelpArrows.stockfish,
                label: kStockfishShortLabel,
              ),
              if (tobyOn)
                const DesktopSegmentedTab(
                  value: PlayHelpArrows.toby,
                  label: 'Toby',
                ),
            ],
            selected: modules.arrows,
            onChanged:
                (arrows) => notifier.set(modules.copyWith(arrows: arrows)),
            expand: true,
          ),
        ],
      ),
    );
  }
}

class _RowText extends StatelessWidget {
  const _RowText({required this.label, required this.description});

  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          description,
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({
    required this.module,
    required this.description,
    required this.value,
    required this.keysLive,
    required this.onChange,
  });

  final PlayHelpModule module;
  final String description;
  final bool value;
  final bool keysLive;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: PlayHelpKeyBinding(
        target: module,
        live: keysLive,
        leading: _RowText(label: module.label, description: description),
        trailing: FSwitch(
          semanticsLabel: module.label,
          value: value,
          onChange: onChange,
        ),
      ),
    );
  }
}

/// A row with a help key's keycap at the right of [leading] (before
/// [trailing]). Clicking the keycap records a new key in place: press one
/// to set it, Esc to cancel, Backspace to clear. A key another action uses
/// asks before it is moved here.
class PlayHelpKeyBinding extends ConsumerStatefulWidget {
  const PlayHelpKeyBinding({
    required this.target,
    required this.leading,
    required this.live,
    this.trailing,
    super.key,
  });

  /// A module, or all help (`null`).
  final PlayHelpTarget target;
  final Widget leading;
  final Widget? trailing;

  /// Whether the keys act in the current style; dimmed when not.
  final bool live;

  @override
  ConsumerState<PlayHelpKeyBinding> createState() => _PlayHelpKeyBindingState();
}

class _PlayHelpKeyBindingState extends ConsumerState<PlayHelpKeyBinding> {
  final FocusNode _focus = FocusNode(debugLabel: 'Play help key recorder');
  FocusNode? _previousFocus;
  bool _recording = false;
  bool _hovered = false;
  bool _focused = false;
  KeyChord? _pending;
  BoardActionKey? _conflict;

  /// Why the last key pressed while recording cannot be a help key.
  String? _note;

  BoardActionKey get _action => playHelpActionFor(widget.target);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    _previousFocus = FocusManager.instance.primaryFocus;
    setState(() {
      _recording = true;
      _pending = null;
      _conflict = null;
      _note = null;
    });
    _focus.requestFocus();
  }

  void _finish() {
    if (!mounted) return;
    setState(() {
      _recording = false;
      _pending = null;
      _conflict = null;
      _note = null;
    });
    // Back to where the keys were going, so a game's keys work at once.
    final previous = _previousFocus;
    _previousFocus = null;
    if (previous != null && previous.context != null && previous != _focus) {
      previous.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  KeyboardShortcutsNotifier get _shortcuts =>
      ref.read(keyboardShortcutsProvider.notifier);

  void _bind(KeyChord chord) {
    unawaited(_shortcuts.setChords(_action, [chord]));
    _finish();
  }

  void _replace() {
    final chord = _pending;
    final other = _conflict;
    if (chord == null || other == null) return;
    unawaited(_shortcuts.moveChord(_action, chord, takeFrom: other));
    _finish();
  }

  /// Another Play key [chord] is bound to: one of the other help keys
  /// (which Replace can take it from) or the threat key. Board-only
  /// actions never act in Play, so a shared chord is no conflict there,
  /// and replacing it would take it from the Board.
  BoardActionKey? _playConflict(BoardShortcutMap map, KeyChord chord) {
    for (final action in BoardActionKey.values) {
      if (action == _action) continue;
      if (!action.isPlayHelp && action != BoardActionKey.showThreat) continue;
      if (map.chordsFor(action).any((c) => c.matches(chord))) return action;
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_recording) {
      // Enter or Space on the focused keycap starts recording.
      final key = event.logicalKey;
      if (event is KeyDownEvent &&
          (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.space)) {
        _start();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (isShortcutModifierKey(key)) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      _finish();
      return KeyEventResult.handled;
    }
    if (_pending != null && key == LogicalKeyboardKey.enter) {
      _replace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      unawaited(_shortcuts.setChords(_action, const []));
      _finish();
      return KeyEventResult.handled;
    }
    final chord = recordedKeyChord(
      key,
      HardwareKeyboard.instance.logicalKeysPressed,
    );
    // Keys that cannot be help keys keep the current binding: recording
    // goes on with a note.
    final reserved =
        isReservedSearchChord(chord)
            ? '${chord.label} opens search.'
            : isPlayNavigationChord(chord)
            ? '${chord.label} steps through moves in Play.'
            : null;
    if (reserved != null) {
      setState(() {
        _pending = null;
        _conflict = null;
        _note = reserved;
      });
      return KeyEventResult.handled;
    }
    final map =
        ref.read(keyboardShortcutsProvider).valueOrNull ??
        BoardShortcutMap(defaultBoardShortcuts());
    final other = _playConflict(map, chord);
    if (other == null) {
      _bind(chord);
    } else if (other == BoardActionKey.showThreat) {
      // The threat button is always in a game; its key stays its own.
      setState(() {
        _pending = null;
        _conflict = null;
        _note = '${chord.label} shows the threat in Play.';
      });
    } else {
      setState(() {
        _pending = chord;
        _conflict = other;
        _note = null;
      });
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final map = watchPlayShortcuts(ref);
    final current = playHelpKeyLabel(map, widget.target);
    final pending = _pending;
    final conflict = _conflict;
    final note = _recording ? _note : null;

    final fg =
        _recording
            ? kPrimaryColor
            : _hovered || _focused
            ? kWhiteColor
            : kWhiteColor70;
    final Widget cap =
        _recording
            ? PlayHelpKeycap(
              label: pending?.label ?? 'Press a key',
              color: kPrimaryColor,
            )
            : current == null
            ? Text(
              'Set key',
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
            : PlayHelpKeycap(label: current, color: fg);

    final keycap = Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (!focused && _recording) _finish();
      },
      child: DesktopTooltip(
        message:
            _recording
                ? 'Press a key. Esc cancels, Backspace clears.'
                : widget.live
                ? 'Change the key'
                : 'Change the key. Keys work in the Peek and Hints styles.',
        child: Semantics(
          button: true,
          label:
              'Key for ${widget.target?.label ?? 'all help'}: '
              '${current ?? 'none'}',
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: ClickCursor(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _recording ? _finish : _start,
                // Keyboard focus shows as a ring round the keycap.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color:
                          _focused && !_recording
                              ? kPrimaryColor.withValues(alpha: 0.35)
                              : const Color(0x00000000),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 140),
                      opacity: widget.live || _recording || _focused ? 1 : 0.45,
                      child: cap,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final trailing = widget.trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: widget.leading),
            const SizedBox(width: 8),
            keycap,
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '$note Press another key.',
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        if (pending != null && conflict != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${pending.label} is used by ${conflict.label}.',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _TextAction(label: 'Replace', onTap: _replace, primary: true),
                const SizedBox(width: 4),
                _TextAction(label: 'Keep', onTap: _finish),
              ],
            ),
          ),
      ],
    );
  }
}

/// A small text action in the sidebar button vocabulary.
class _TextAction extends StatefulWidget {
  const _TextAction({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.primary
            ? kPrimaryColor
            : _hovered
            ? kWhiteColor
            : kWhiteColor70;
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: ClickCursor(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color:
                    widget.primary
                        ? kPrimaryColor.withValues(
                          alpha: _hovered ? 0.16 : 0.10,
                        )
                        : _hovered
                        ? kBlack3Color
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      widget.primary
                          ? kPrimaryColor.withValues(alpha: 0.35)
                          : kDividerColor,
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether the in-game Live help section is open. Shared by every Play
/// tab for the session, and closed to begin with: the switches stay out of
/// the way until the player asks for them.
final playHelpSectionExpandedProvider = StateProvider<bool>((ref) => false);

/// The help modules during a game: one quiet "Live help" row that opens
/// [PlayHelpModulesList] in place, so the player can change what they see
/// without leaving the board.
class PlayHelpModulesSection extends ConsumerWidget {
  const PlayHelpModulesSection({this.tabId, super.key});

  /// The game's tab: a help style changed mid-game says it starts with the
  /// next game.
  final String? tabId;

  /// Taller lists scroll inside the section instead of pushing the game's
  /// controls off the panel.
  static const double _maxListHeight = 300;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(playHelpSectionExpandedProvider);
    final modules = ref.watch(playHelpModulesProvider);
    final level = ref.watch(playHelpStyleProvider.select((s) => s.level));
    final id = tabId;
    final styleChangedMidGame =
        id != null &&
        ref.watch(playHelpUsageProvider(id).select((u) => u.level)) != level;
    final onCount =
        [
          modules.engineLines,
          modules.evalBar,
          modules.tobyPredictions,
          modules.tobyBar,
          modules.moveMarks,
          modules.explorer,
          modules.arrowEvals,
          modules.arrows != PlayHelpArrows.off,
        ].where((on) => on).length;

    return FTheme(
      data: FThemes.zinc.dark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FTappable(
            style:
                (style) => style.copyWith(motion: (_) => FTappableMotion.none),
            semanticsLabel: expanded ? 'Hide live help' : 'Show live help',
            onPress:
                () =>
                    ref.read(playHelpSectionExpandedProvider.notifier).state =
                        !expanded,
            builder: (context, states, _) {
              final hovered = states.contains(WidgetState.hovered);
              final foreground = hovered ? kWhiteColor : kWhiteColor70;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: hovered ? kBlack3Color : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDividerColor),
                ),
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 16, color: foreground),
                    const SizedBox(width: 8),
                    Text(
                      'Live help',
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      onCount == 0
                          ? 'Off'
                          : level == PlayHelpLevel.always
                          ? '$onCount on'
                          : '$onCount on, ${level.label.toLowerCase()}',
                      style: const TextStyle(
                        color: kSecondaryTextColor,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child:
                expanded
                    ? Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                      child: PlayShrinkingScroller(
                        maxHeight: _maxListHeight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (styleChangedMidGame) ...[
                              const Text(
                                'Your new help style starts with your '
                                'next game.',
                                style: TextStyle(
                                  color: kWhiteColor70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            const PlayHelpModulesList(),
                          ],
                        ),
                      ),
                    )
                    : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// A vertical scroller that is as tall as its [child] up to [maxHeight],
/// then scrolls with no scrollbar: arrows at the ends say there is more
/// ([ScrollEdgeArrows]). Short content never grows to [maxHeight].
class PlayShrinkingScroller extends StatelessWidget {
  const PlayShrinkingScroller({
    required this.maxHeight,
    required this.child,
    super.key,
  });

  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Sized in one layout pass: the first frame is already the content's
    // height (capped at [maxHeight]), never [maxHeight] first.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ScrollEdgeArrows(
        shrinkWrap: true,
        child: SingleChildScrollView(child: child),
      ),
    );
  }
}
