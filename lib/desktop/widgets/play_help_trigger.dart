import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/editable_aware_shortcut_activator.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/theme/app_theme.dart';

/// Play's help actions and what each reveals: all of the chosen help
/// (`null`) or one module.
const Map<BoardActionKey, PlayHelpTarget> kPlayHelpActions = {
  BoardActionKey.playHelpAll: null,
  BoardActionKey.playHelpEngineLines: PlayHelpModule.engineLines,
  BoardActionKey.playHelpEvalBar: PlayHelpModule.evalBar,
  BoardActionKey.playHelpTobyPredictions: PlayHelpModule.tobyPredictions,
  BoardActionKey.playHelpTobyBar: PlayHelpModule.tobyBar,
  BoardActionKey.playHelpMoveMarks: PlayHelpModule.moveMarks,
  BoardActionKey.playHelpExplorer: PlayHelpModule.explorer,
  BoardActionKey.playHelpArrowEvals: PlayHelpModule.arrowEvals,
  BoardActionKey.playHelpArrows: PlayHelpModule.arrows,
};

/// The shortcut action for [target].
BoardActionKey playHelpActionFor(PlayHelpTarget target) => switch (target) {
  null => BoardActionKey.playHelpAll,
  PlayHelpModule.engineLines => BoardActionKey.playHelpEngineLines,
  PlayHelpModule.evalBar => BoardActionKey.playHelpEvalBar,
  PlayHelpModule.tobyPredictions => BoardActionKey.playHelpTobyPredictions,
  PlayHelpModule.tobyBar => BoardActionKey.playHelpTobyBar,
  PlayHelpModule.moveMarks => BoardActionKey.playHelpMoveMarks,
  PlayHelpModule.explorer => BoardActionKey.playHelpExplorer,
  PlayHelpModule.arrowEvals => BoardActionKey.playHelpArrowEvals,
  PlayHelpModule.arrows => BoardActionKey.playHelpArrows,
};

/// The player's key bindings, or the defaults until they load.
BoardShortcutMap watchPlayShortcuts(WidgetRef ref) =>
    ref.watch(keyboardShortcutsProvider).valueOrNull ??
    BoardShortcutMap(defaultBoardShortcuts());

/// The first key bound to [target]'s help action, as the player reads it,
/// or null when none is.
String? playHelpKeyLabel(BoardShortcutMap map, PlayHelpTarget target) =>
    map.chordsFor(playHelpActionFor(target)).firstOrNull?.label;

/// Play's fixed move keys (Home, End, Left, Right with no modifier). They
/// step through the game and cannot be help keys.
final Set<LogicalKeyboardKey> kPlayNavigationKeys = {
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

/// Whether [chord] is one of Play's fixed move keys.
bool isPlayNavigationChord(KeyChord chord) =>
    !chord.ctrl &&
    !chord.meta &&
    !chord.alt &&
    !chord.shift &&
    !chord.crossPlatform &&
    kPlayNavigationKeys.any((key) => key.keyId == chord.keyId);

/// The help action a key going down with these modifiers fires, if any.
/// Global search (Cmd/Ctrl+F, any Shift) and Play's move keys never fire
/// one, whatever is stored.
BoardActionKey? playHelpActionForKeyDown(
  BoardShortcutMap map,
  LogicalKeyboardKey key, {
  bool ctrl = false,
  bool meta = false,
  bool alt = false,
  bool shift = false,
}) {
  if (key == LogicalKeyboardKey.keyF && (ctrl || meta)) return null;
  if (!ctrl && !meta && !alt && !shift && kPlayNavigationKeys.contains(key)) {
    return null;
  }
  for (final action in kPlayHelpActions.keys) {
    for (final chord in map.chordsFor(action)) {
      if (chord.keyId == key.keyId &&
          chord.matchesPressedModifiers(
            ctrl: ctrl,
            meta: meta,
            alt: alt,
            shift: shift,
          )) {
        return action;
      }
    }
  }
  return null;
}

/// The help actions bound to [key] with any modifiers. A key coming up
/// ends their peeks: the modifiers may have been let go first.
List<BoardActionKey> playHelpActionsForKey(
  BoardShortcutMap map,
  LogicalKeyboardKey key,
) => [
  for (final action in kPlayHelpActions.keys)
    if (map.chordsFor(action).any((chord) => chord.keyId == key.keyId)) action,
];

/// Handles Play's help keys for the game in [tabId], as the player bound
/// them: a key going down begins a peek or spends a hint on its target
/// (one module or all help), coming up ends that peek. Key repeat does
/// nothing. A key for a module that is not switched on does nothing and
/// costs nothing; in the Always on style no key does anything. Returns
/// whether the event was a help key it acted on.
bool handlePlayHelpKey(WidgetRef ref, String tabId, KeyEvent event) {
  // A text field keeps its keys.
  if (focusIsEditingText(FocusManager.instance.primaryFocus)) return false;
  final usage = ref.read(playHelpUsageProvider(tabId).notifier);
  final level = ref.read(playHelpUsageProvider(tabId)).level;
  if (level == PlayHelpLevel.always) return false;
  final map =
      ref.read(keyboardShortcutsProvider).valueOrNull ??
      BoardShortcutMap(defaultBoardShortcuts());
  if (event is KeyUpEvent) {
    final actions = playHelpActionsForKey(map, event.logicalKey);
    for (final action in actions) {
      usage.endPeekOf(kPlayHelpActions[action]);
    }
    return actions.isNotEmpty;
  }
  final keyboard = HardwareKeyboard.instance;
  final action = playHelpActionForKeyDown(
    map,
    event.logicalKey,
    ctrl: keyboard.isControlPressed,
    meta: keyboard.isMetaPressed,
    alt: keyboard.isAltPressed,
    shift: keyboard.isShiftPressed,
  );
  if (action == null) return false;
  if (event is KeyRepeatEvent) return true;
  final target = kPlayHelpActions[action];
  return level == PlayHelpLevel.peek
      ? usage.beginPeek(target)
      : usage.useHint(target);
}

/// Calls [release] when the pointer that sent [down] comes up, wherever it
/// is then. A help shelf chip is replaced by the help it reveals, so it
/// cannot wait for its own pointer-up.
void _onPointerRelease(PointerDownEvent down, VoidCallback release) {
  final router = GestureBinding.instance.pointerRouter;
  late final PointerRoute route;
  route = (event) {
    if (event.pointer != down.pointer) return;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      router.removeGlobalRoute(route);
      release();
    }
  };
  router.addGlobalRoute(route);
}

/// Whether the game in [tabId] holds its help back and has some to give:
/// the peek or hint control is worth showing.
bool playHelpIsHeldBack(WidgetRef ref, String tabId) {
  final level = ref.watch(playHelpUsageProvider(tabId).select((u) => u.level));
  final chosen = ref.watch(playHelpModulesProvider.select((m) => m.anyOn));
  return chosen && level != PlayHelpLevel.always;
}

/// Whether every chosen module is revealed in [tabId].
bool _allShown(WidgetRef ref, String tabId) {
  final chosen = ref.watch(playHelpModulesProvider);
  final revealed = ref.watch(playHelpRevealedModulesProvider(tabId));
  return chosen.chosenModules.every(revealed.contains);
}

/// The peek or hint control beside the player's clock. Hold to peek: the
/// help shows while it is held and a fill runs across it. Hints: a press
/// spends one, the pips under the label empty one by one.
class PlayHelpTrigger extends ConsumerStatefulWidget {
  const PlayHelpTrigger({required this.tabId, this.compact = false, super.key});

  final String tabId;

  /// A narrow row: the glyph (and the hint pips) only; the label moves to
  /// the tooltip.
  final bool compact;

  @override
  ConsumerState<PlayHelpTrigger> createState() => _PlayHelpTriggerState();
}

class _PlayHelpTriggerState extends ConsumerState<PlayHelpTrigger> {
  bool _hovered = false;
  late final PlayHelpUsageNotifier _usage;

  @override
  void initState() {
    super.initState();
    // Read now: dispose cannot read providers.
    _usage = ref.read(playHelpUsageProvider(widget.tabId).notifier);
  }

  @override
  void dispose() {
    // A peek never outlives its control.
    _usage.endPeekOf(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = ref.watch(playHelpUsageProvider(widget.tabId));
    final revealed = ref.watch(playHelpRevealedProvider(widget.tabId));
    final allShown = _allShown(ref, widget.tabId);
    final peek = usage.level == PlayHelpLevel.peek;
    final myTurn = ref.watch(
      playSessionProviderFor(widget.tabId).select((s) => s.isHumanToMove),
    );
    final enabled = peek || revealed || (usage.hintsLeft > 0 && myTurn);
    final active = peek ? usage.peeking : revealed;
    // The all-help key, as the player bound it.
    final key = playHelpKeyLabel(watchPlayShortcuts(ref), null);

    final label =
        peek
            ? (active ? 'Peeking' : 'Peek')
            : allShown
            ? 'Hint shown'
            : usage.hintsLeft > 0
            ? 'Hint'
            : active
            ? 'Hint shown'
            : 'No hints';
    final tooltip =
        peek
            ? '$label: hold to see all your help for this position'
                '${key == null ? '' : ' (hold $key)'}'
            : usage.hintsLeft > 0 && !myTurn
            ? 'Hints are spent on your turn. '
                '${usage.hintsLeft} of ${usage.allowance} left'
            : usage.hintsLeft > 0
            ? 'See all your help until your next move'
                '${key == null ? '' : ' ($key)'}. '
                '${usage.hintsLeft} of ${usage.allowance} left'
            : 'No hints left this game';

    final fg =
        !enabled
            ? kLightGreyColor
            : active
            ? kPrimaryColor
            : _hovered
            ? kWhiteColor
            : kWhiteColor70;

    final pill = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      height: 34,
      decoration: BoxDecoration(
        color:
            active
                ? kPrimaryColor.withValues(alpha: 0.10)
                : _hovered && enabled
                ? kBlack3Color
                : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? kPrimaryColor.withValues(alpha: 0.35) : kDividerColor,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Stack(
          children: [
            // Peeking: a fill runs the full width of the pill while it is
            // held, and drains back on release.
            if (peek)
              Positioned.fill(
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: active ? 1 : 0),
                  duration: Duration(milliseconds: active ? 220 : 160),
                  curve: Curves.easeOutCubic,
                  builder:
                      (context, t, _) => FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: t,
                        child: ColoredBox(
                          color: kPrimaryColor.withValues(alpha: 0.12),
                        ),
                      ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    peek
                        ? (active
                            ? Icons.visibility_rounded
                            : Icons.visibility_outlined)
                        : Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: fg,
                  ),
                  if (!widget.compact) ...[
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (!peek) ...[
                    const SizedBox(width: 9),
                    _HintPips(
                      left: usage.hintsLeft,
                      total: usage.allowance,
                      color: enabled ? fg : kLightGreyColor,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final interactive =
        peek
            ? Listener(
              onPointerDown: (_) => _usage.beginPeek(),
              onPointerUp: (_) => _usage.endPeekOf(null),
              onPointerCancel: (_) => _usage.endPeekOf(null),
              child: pill,
            )
            : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? _usage.useHint : null,
              child: pill,
            );

    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: DesktopTooltip(
        message: tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: enabled ? ClickCursor(child: interactive) : interactive,
        ),
      ),
    );
  }
}

/// One dot per hint: full while left, an empty ring once spent. The one
/// just spent shrinks into its ring.
class _HintPips extends StatelessWidget {
  const _HintPips({
    required this.left,
    required this.total,
    required this.color,
  });

  final int left;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: i < left ? 1 : 0),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutBack,
            builder:
                (context, t, _) => SizedBox.square(
                  dimension: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color.withValues(alpha: 0.55),
                        width: 1,
                      ),
                    ),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 6 * t.clamp(0.0, 1.2),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          ),
        ],
      ],
    );
  }
}

/// The help shelf: where the rail's help would be while it is held back.
/// It lists the chosen modules, each with its key, and an All help entry.
/// Holding a key or an entry (peek style) shows that help for the
/// position; pressing one (hints style) spends a hint on it.
class PlayHelpCurtain extends ConsumerWidget {
  const PlayHelpCurtain({required this.tabId, super.key});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(playHelpUsageProvider(tabId));
    final notifier = ref.read(playHelpUsageProvider(tabId).notifier);
    final chosen = ref.watch(playHelpModulesProvider);
    final revealed = ref.watch(playHelpRevealedModulesProvider(tabId));
    final allShown = _allShown(ref, tabId);
    final shortcuts = watchPlayShortcuts(ref);
    final myTurn = ref.watch(
      playSessionProviderFor(tabId).select((s) => s.isHumanToMove),
    );
    final peek = usage.level == PlayHelpLevel.peek;
    final canHint = usage.hintsLeft > 0 && myTurn;

    final targets = <PlayHelpTarget>[null, ...chosen.chosenModules];
    String labelOf(PlayHelpTarget target) =>
        target?.labelIn(chosen) ?? 'All help';

    Widget chip(PlayHelpTarget target, {bool keysOnly = false}) {
      final active = target == null ? allShown : revealed.contains(target);
      final keyLabel = playHelpKeyLabel(shortcuts, target);
      return _ShelfChip(
        label: labelOf(target),
        keyLabel: keyLabel,
        // A pane too small for every name shows a module as its key
        // alone, named in a tooltip. All help keeps its name.
        keyOnly: keysOnly && target != null && keyLabel != null,
        active: active,
        enabled: peek || active || canHint,
        hold: peek,
        onHoldStart: () => notifier.beginPeek(target),
        onHoldEnd: () => notifier.endPeekOf(target),
        onPress: () => notifier.useHint(target),
      );
    }

    List<Widget> chips({bool keysOnly = false}) => [
      for (final target in targets) chip(target, keysOnly: keysOnly),
    ];
    final verb = Text(
      peek ? 'Hold' : 'Hint',
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
    final pips =
        peek
            ? null
            : _HintPips(
              left: usage.hintsLeft,
              total: usage.allowance,
              color: usage.hintsLeft > 0 ? kWhiteColor70 : kLightGreyColor,
            );
    final how =
        peek
            ? 'Hold a key or an entry to see that help for this position.'
            : usage.hintsLeft <= 0
            ? 'No hints left this game.'
            : !myTurn
            ? 'Hints are spent on your turn. '
                '${usage.hintsLeft} of ${usage.allowance} left.'
            : 'Press a key or an entry to see that help until your next '
                'move. Each costs a hint. ${usage.hintsLeft} of '
                '${usage.allowance} left.';

    final tall = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your help is held back',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (pips != null) ...[const SizedBox(width: 10), pips],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          how,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: chips(),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // A short engine pane gets the verb, the hints left and the
        // entries on one row, modules as their keys alone if their names
        // do not fit, and arrows at the sides when even that runs past
        // the pane. A tall one also says what to do, with every entry
        // named.
        final compact = constraints.maxHeight < 210;
        return Container(
          width: double.infinity,
          height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
          padding:
              compact
                  ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8)
                  : const EdgeInsets.fromLTRB(20, 18, 20, 18),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(10),
          ),
          child:
              compact
                  ? Row(
                    children: [
                      // The verb and the hints left stay pinned; only the
                      // entries scroll.
                      verb,
                      if (pips != null) ...[const SizedBox(width: 8), pips],
                      const SizedBox(width: _kShelfChipGap * 2),
                      Expanded(
                        child: SizedBox(
                          height: _kShelfChipHeight,
                          child: LayoutBuilder(
                            builder: (context, box) {
                              final keysOnly =
                                  !_shelfChipsFitRow([
                                    for (final target in targets)
                                      _shelfChipWidth(
                                        context,
                                        label: labelOf(target),
                                        keyLabel: playHelpKeyLabel(
                                          shortcuts,
                                          target,
                                        ),
                                      ),
                                  ], box);
                              return ScrollEdgeArrows(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final (i, entry)
                                          in chips(
                                            keysOnly: keysOnly,
                                          ).indexed) ...[
                                        if (i > 0)
                                          const SizedBox(width: _kShelfChipGap),
                                        entry,
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  )
                  : constraints.hasBoundedHeight
                  ? ScrollEdgeArrows(
                    axis: Axis.vertical,
                    child: LayoutBuilder(
                      builder:
                          (context, box) => SingleChildScrollView(
                            child: ConstrainedBox(
                              // Short content still sits in the middle.
                              constraints: BoxConstraints(
                                minHeight: box.maxHeight,
                                minWidth: box.maxWidth,
                              ),
                              child: Center(child: tall),
                            ),
                          ),
                    ),
                  )
                  : tall,
        );
      },
    );
  }
}

const double _kShelfChipHeight = 30;
const double _kShelfChipGap = 6;

/// Width of a [_ShelfChip] with [label] and [keyLabel], measured the way
/// it is laid out.
double _shelfChipWidth(
  BuildContext context, {
  required String label,
  required String? keyLabel,
}) {
  double measure(String text, double size) =>
      _measureShelfText(context, text, size: size, weight: FontWeight.w600);

  // Border (1 each side) plus padding, as in _ShelfChip and PlayHelpKeycap.
  const border = 2.0;
  if (keyLabel == null) return border + 10 + measure(label, 12) + 10;
  final cap = (measure(keyLabel, 11) + 10).clamp(20.0, double.infinity);
  return border + 5 + cap + 7 + measure(label, 12) + 10;
}

double _measureShelfText(
  BuildContext context,
  String text, {
  required double size,
  required FontWeight weight,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(
        context,
      ).style.copyWith(fontSize: size, fontWeight: weight),
    ),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Whether chips of [widths], in one row like the shelf's, fit [box].
bool _shelfChipsFitRow(List<double> widths, BoxConstraints box) {
  if (!box.hasBoundedWidth) return true;
  var line = 0.0;
  for (final width in widths) {
    // A pixel of slack per chip for rounding.
    line += (line == 0 ? 0 : _kShelfChipGap) + width + 1;
  }
  return line <= box.maxWidth;
}

/// A key as the player presses it: a small bordered cap, no fill.
class PlayHelpKeycap extends StatelessWidget {
  const PlayHelpKeycap({required this.label, this.color, super.key});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? kWhiteColor70;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        textHeightBehavior: const TextHeightBehavior(
          applyHeightToFirstAscent: false,
          applyHeightToLastDescent: false,
        ),
        style: TextStyle(
          color: fg,
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One entry on the help shelf, in the sidebar button vocabulary: held to
/// peek, pressed to spend a hint.
class _ShelfChip extends StatefulWidget {
  const _ShelfChip({
    required this.label,
    required this.keyLabel,
    required this.active,
    required this.enabled,
    required this.hold,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onPress,
    this.keyOnly = false,
  });

  final String label;
  final String? keyLabel;

  /// Shows the key alone, with [label] in a tooltip (a short pane).
  final bool keyOnly;
  final bool active;
  final bool enabled;
  final bool hold;
  final bool Function() onHoldStart;
  final VoidCallback onHoldEnd;
  final bool Function() onPress;

  @override
  State<_ShelfChip> createState() => _ShelfChipState();
}

class _ShelfChipState extends State<_ShelfChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final active = widget.active;
    final fg =
        !enabled
            ? kLightGreyColor
            : active
            ? kPrimaryColor
            : _hovered
            ? kWhiteColor
            : kWhiteColor70;
    final key = widget.keyLabel;
    final keyOnly = widget.keyOnly && key != null;
    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      height: _kShelfChipHeight,
      padding: EdgeInsets.only(
        left: key == null ? 10 : 5,
        right: keyOnly ? 5 : 10,
      ),
      decoration: BoxDecoration(
        color:
            active
                ? kPrimaryColor.withValues(alpha: _hovered ? 0.16 : 0.10)
                : _hovered && enabled
                ? kBlack3Color
                : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? kPrimaryColor.withValues(alpha: 0.35) : kDividerColor,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (key != null) PlayHelpKeycap(label: key, color: fg),
          if (!keyOnly) ...[
            if (key != null) const SizedBox(width: 7),
            Text(
              widget.label,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
    final Widget interactive =
        widget.hold
            ? Listener(
              onPointerDown: (down) {
                // The help it reveals may take the shelf's place: the
                // release is caught wherever the pointer is then.
                if (widget.onHoldStart()) {
                  _onPointerRelease(down, widget.onHoldEnd);
                }
              },
              child: body,
            )
            : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? () => widget.onPress() : null,
              child: body,
            );
    final Widget chip = Semantics(
      button: true,
      enabled: enabled,
      label:
          '${widget.hold ? 'Hold to see' : 'Hint:'} ${widget.label}'
          '${key == null ? '' : ', key $key'}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: enabled ? ClickCursor(child: interactive) : interactive,
      ),
    );
    return keyOnly ? DesktopTooltip(message: widget.label, child: chip) : chip;
  }
}

/// A bar's place beside the board while its help is held back: the same
/// room, empty, so peeking never moves the board.
class PlayHeldBackBar extends StatelessWidget {
  const PlayHeldBackBar({required this.width, required this.height, super.key});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// Help that has just been revealed settles into place: it is on screen
/// from the first frame and only slides the last few pixels.
class PlayHelpReveal extends StatelessWidget {
  const PlayHelpReveal({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 8, end: 0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder:
          (context, dy, child) =>
              Transform.translate(offset: Offset(0, dy), child: child),
      child: child,
    );
  }
}

/// How the chosen help reaches the player, picked like a game's
/// difficulty, with what each choice does to a win's rating gain.
class PlayHelpStylePicker extends ConsumerWidget {
  const PlayHelpStylePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(playHelpStyleProvider);
    final notifier = ref.read(playHelpStyleProvider.notifier);
    final allKey = playHelpKeyLabel(watchPlayShortcuts(ref), null);
    final orAll = allKey == null ? '' : ' or $allKey';
    const moduleKeys = 'Each module has its own key, shown beside it below.';
    final note = switch (style.level) {
      PlayHelpLevel.always =>
        'Your help shows the whole game. A win with it on keeps a quarter '
            'of its rating gain.',
      PlayHelpLevel.peek =>
        'Hidden until you hold Peek$orAll. $moduleKeys Each position you '
            'peek at takes 8% off a win’s rating gain.',
      PlayHelpLevel.hints =>
        'Hidden until you press Hint$orAll, then shown until your next '
            'move. $moduleKeys Each hint, one module or all, takes 10% off '
            'a win’s rating gain.',
    };

    return FTheme(
      data: FThemes.zinc.dark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Help style',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          DesktopSegmentedTabs<PlayHelpLevel>(
            tabs: [
              for (final level in PlayHelpLevel.values)
                DesktopSegmentedTab(value: level, label: level.shortLabel),
            ],
            selected: style.level,
            onChanged: (level) => notifier.set(style.copyWith(level: level)),
            expand: true,
          ),
          const SizedBox(height: 8),
          Text(
            note,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          // Only the hints style has a count to choose; the row keeps its
          // room in every style so the switches below never jump.
          const SizedBox(height: 10),
          Visibility(
            visible: style.level == PlayHelpLevel.hints,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Hints a game',
                    style: TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: DesktopSegmentedTabs<int>(
                    tabs: [
                      for (final n in kPlayHintAllowances)
                        DesktopSegmentedTab(value: n, label: '$n'),
                    ],
                    selected: style.hints,
                    onChanged: (n) => notifier.set(style.copyWith(hints: n)),
                    expand: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
