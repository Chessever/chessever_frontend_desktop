/// "What Toby Thinks": Toby's prediction of the move a human plays next,
/// directly under the Stockfish lines.
///
/// Collapsed it is one 32 px row and asks nothing. Expanded (Premium) it is a
/// fixed-height block: a header with the position's verdict, five candidate
/// slots (three when the engine pane is short, see [TobyPanelSlots]), the
/// inputs Toby used (which open the what-if menu) and Toby's attribution.
/// Its height never follows the reading: it changes on expand and collapse,
/// or when the pane is resized.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/services/toby/toby_access.dart';
import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';

const double _kHeaderHeight = kTobyPanelCollapsedHeight;
const double _kRowHeight = kTobyPanelSlotHeight;
const double _kMetaHeight = 22;
const double _kAttributionHeight = 18;
const double _kBottomPadding =
    kTobyPanelFooterHeight - _kMetaHeight - _kAttributionHeight;

/// Narrower than this, the per-move outcome bars step aside (their numbers
/// stay in the row's semantics).
const double _kWdlMinPanelWidth = 320;

/// Lines up with the Stockfish rows: their list inset, then their 1 px
/// border and 8 px padding, so Toby's text starts where their scores do and
/// its chevron sits over theirs.
const double _kListInset = 16;
const double _kRowPadding = 1 + 8;
const double _kContentInset = _kListInset + _kRowPadding;

/// Stockfish's score column, so SANs sit under the scores.
const double _kSanWidth = 56;

/// A Stockfish line's moves open with a move number, and its figure sits
/// about 1 px inside the text's box (12 px tabular figures, measured in SF
/// Pro and Inter). The bars start where those figures do, not 1 px ahead.
const double _kPvFigureInset = 1;

const double _kPercentWidth = 40;
const double _kWdlWidth = 40;

const Color _kWdlWhite = Color(0xFFE8E6E1);
const Color _kWdlDraw = Color(0xFF8E8E93);
const Color _kWdlBlack = Color(0xFF3A3A3C);

/// Muted bars for the quick network stage.
const double _kNetworkAlpha = 0.45;

const String _kThinking = 'Toby is thinking…';
const String _kBusy = 'Toby is busy right now';
const String _kTryAgain = 'Try again';

/// Space between the pieces of the inputs row.
const double _kMetaGap = 8;

/// Space between the label and the position verdict in the header.
const double _kVerdictGap = 10;

const TextStyle _kLabelStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w600,
);
const TextStyle _kVerdictStyle = TextStyle(
  color: kWhiteColor70,
  fontSize: 12,
  fontFeatures: [FontFeature.tabularFigures()],
);
const TextStyle _kMetaStyle = TextStyle(
  color: kSecondaryTextColor,
  fontSize: 11,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// The width [text] takes on one line in [style], laid out as a [Text]
/// here would lay it out.
double _textWidth(BuildContext context, String text, TextStyle style) {
  var effective = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) {
    effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  final painter = TextPainter(
    text: TextSpan(text: text, style: effective),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// How many candidate slots the expanded panel below shows. The engine pane
/// chooses it from the room it has ([tobyPanelSlotsFor]), so two Stockfish
/// lines always stay in view; the panel never chooses it from the reading.
/// Without one the panel shows [kTobyPanelSlots].
class TobyPanelSlots extends InheritedWidget {
  const TobyPanelSlots({super.key, required this.slots, required super.child});

  final int slots;

  static int of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TobyPanelSlots>()?.slots ??
      kTobyPanelSlots;

  @override
  bool updateShouldNotify(TobyPanelSlots oldWidget) => oldWidget.slots != slots;
}

/// Why the panel reads nothing for the board's position.
enum TobyIdleReason {
  /// The game is not standard chess.
  variant('Toby reads standard chess positions'),

  /// Checkmate, stalemate or a draw by rule.
  gameOver('Game over'),

  /// An explorer line or a threat is on the board instead of the position.
  preview('Paused while previewing'),

  /// Another board holds the engine and the keyboard.
  background('Resumes when this board is active');

  const TobyIdleReason(this.message);

  final String message;
}

/// What the board asks the panel to read: a request for the position on the
/// board, or why there is none.
@immutable
class TobyTarget {
  const TobyTarget.read(
    TobyRequest this.request, {
    required String this.positionKey,
  }) : idle = null;

  const TobyTarget.idle(TobyIdleReason this.idle)
    : request = null,
      positionKey = null;

  final TobyRequest? request;

  /// The FEN of the position read. The board draws Toby's arrow only while
  /// it shows this exact position.
  final String? positionKey;
  final TobyIdleReason? idle;
}

/// Decides what the panel of one board reads. [request] is only built when
/// the position can be read.
TobyTarget resolveTobyTarget({
  required bool foreground,
  required bool previewing,
  required bool gameOver,
  required String? variant,
  required String positionKey,
  required TobyRequest Function() request,
}) {
  if (!tobyReadsVariant(variant)) {
    return const TobyTarget.idle(TobyIdleReason.variant);
  }
  if (!foreground) return const TobyTarget.idle(TobyIdleReason.background);
  if (previewing) return const TobyTarget.idle(TobyIdleReason.preview);
  if (gameOver) return const TobyTarget.idle(TobyIdleReason.gameOver);
  return TobyTarget.read(request(), positionKey: positionKey);
}

/// The panel. The board pane builds it with an immutable [target] and its
/// own [controller]; the panel alone watches Toby's reading, so nothing is
/// asked while it is collapsed, the reader is not Premium, or it is not
/// mounted.
class WhatTobyThinks extends ConsumerStatefulWidget {
  const WhatTobyThinks({
    super.key,
    required this.target,
    required this.controller,
    this.onPlayUci,
  });

  final TobyTarget target;
  final TobyPanelController controller;

  /// Plays a candidate on the board, through the same path as a Stockfish
  /// row. Null hides "Play" from the row menu.
  final void Function(String uci)? onPlayUci;

  @override
  ConsumerState<WhatTobyThinks> createState() => _WhatTobyThinksState();
}

class _WhatTobyThinksState extends ConsumerState<WhatTobyThinks> {
  final FocusNode _rowsFocus = FocusNode(debugLabel: 'Toby candidates');

  /// The what-if menu's focus scope. Focus moves into the menu when it
  /// opens, so the keyboard lands in it and Esc closes the menu (forui's
  /// shortcut) instead of reaching the board, where it closes the tab.
  final FocusScopeNode _whatIfFocus = FocusScopeNode(
    debugLabel: 'Toby what-if',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );

  /// The row keyboard focus rests on. Shown (and drawn on the board) when
  /// focus arrives by keyboard or after Up/Down, so a mouse click leaves no
  /// focus arrow behind.
  int _focusedRow = 0;
  bool _keyboard = false;

  /// Set while a click on a row is moving focus to the rows, so the focus
  /// change is not read as Tab.
  bool _focusByPointer = false;

  /// The candidates on screen, for focus that arrives between builds.
  List<TobyCandidate> _visibleRows = const <TobyCandidate>[];

  /// An Esc that cleared the pin also owns its key repeats, so holding it
  /// cannot go on to close the tab.
  bool _escapeConsumed = false;

  /// The reader just opened the panel: its first request goes out at once,
  /// with no navigation to settle.
  bool _openedByReader = false;

  /// The what-if menu keeps its state while the inputs row rearranges
  /// around it (a reading arriving, a busy notice).
  final GlobalKey _whatIfKey = GlobalKey(debugLabel: 'Toby what-if');

  TobyPanelController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _rowsFocus.addListener(_onRowsFocusChanged);
  }

  @override
  void didUpdateWidget(covariant WhatTobyThinks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (oldWidget.target.positionKey != widget.target.positionKey) {
      _focusedRow = 0;
      _keyboard = false;
      // The board is building this frame too; clear after it.
      _controller.clearMarksSoon();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // No arrow outlives the panel that drew it (picture-in-picture, a
    // collapsed engine pane, the panel moving when the report opens).
    _controller.clearMarksSoon();
    _rowsFocus
      ..removeListener(_onRowsFocusChanged)
      ..dispose();
    _whatIfFocus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onRowsFocusChanged() {
    final byPointer = _focusByPointer;
    _focusByPointer = false;
    if (_rowsFocus.hasFocus) {
      // Focus that arrives by keyboard (Tab) shows its row and arrow at once.
      if (!byPointer &&
          FocusManager.instance.highlightMode ==
              FocusHighlightMode.traditional) {
        _focusRowByKeyboard();
      }
      return;
    }
    if (_keyboard) {
      _keyboard = false;
      _controller.clearHover();
    }
    if (mounted) setState(() {});
  }

  void _focusRowByKeyboard() {
    final positionKey = widget.target.positionKey;
    final visible = _visibleRows;
    if (!mounted || positionKey == null || visible.isEmpty) return;
    final row = _focusedRow.clamp(0, visible.length - 1);
    setState(() {
      _keyboard = true;
      _focusedRow = row;
    });
    _controller.hover(positionKey, visible[row].uci);
  }

  /// A collapse the header did not cause (sign-out, a lapsed membership)
  /// unmounts the rows without a pointer exit: clear what they put on the
  /// board.
  void _onExpandedChanged(bool? _, bool expanded) {
    if (expanded) return;
    _keyboard = false;
    _controller.clearMarksSoon();
  }

  void _toggleWhatIf(FPopoverController popover) {
    final opening =
        popover.status == AnimationStatus.dismissed ||
        popover.status == AnimationStatus.forward;
    unawaited(popover.toggle());
    if (!opening) return;
    // The menu is built in the next frame. Focus that stays outside it
    // (an autofocus never takes it from the board) would let Esc close the
    // board tab under an open menu.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && popover.status.isForwardOrCompleted) {
        _whatIfFocus.requestFocus();
      }
    });
  }

  void _open() {
    if (!mounted) return;
    final admitted = admitTobyPrediction(
      _windowContainer(context),
      surface: 'toby_panel_expand',
      resume: DesktopAccessResume(run: _open, stillMatches: () => mounted),
    );
    if (!admitted) return;
    _openedByReader = true;
    ref.read(tobyPanelOpenPreferenceProvider.notifier).choose(true);
  }

  void _collapse() {
    _keyboard = false;
    _controller.clearMarks();
    ref.read(tobyPanelOpenPreferenceProvider.notifier).choose(false);
  }

  void _togglePin(String uci) {
    final positionKey = widget.target.positionKey;
    if (positionKey == null) return;
    _controller.togglePin(positionKey, uci);
  }

  Future<void> _showRowMenu(TobyCandidate candidate, Offset position) async {
    final play = widget.onPlayUci;
    final positionKey = widget.target.positionKey;
    if (play == null || positionKey == null) return;
    final picked = await showDesktopContextMenu<String>(
      context: context,
      position: position,
      entries: [
        DesktopContextMenuItem<String>(
          value: 'play',
          icon: Icons.play_arrow_rounded,
          label: 'Play ${candidate.san}',
        ),
      ],
    );
    if (picked != 'play' || !mounted) return;
    // The board may have moved on while the menu was open.
    if (widget.target.positionKey != positionKey) return;
    widget.onPlayUci?.call(candidate.uci);
  }

  /// Esc anywhere inside the panel (rows, header, what-if menu). It closes
  /// the board tab elsewhere, so it means "unpin" here only while there is a
  /// pin to clear; otherwise it passes on.
  KeyEventResult _onPanelKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      _escapeConsumed = false;
      return KeyEventResult.ignored;
    }
    if (_modifierPressed()) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) {
      return _escapeConsumed ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    _escapeConsumed = _controller.clearPin();
    return _escapeConsumed ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Up/Down walk the candidates, Enter pins one. Everything else (Space
  /// plays Stockfish's move, ←/→ step the game) passes on to the rail.
  KeyEventResult _onRowsKey(KeyEvent event, List<TobyCandidate> visible) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // Chords belong to the shell (Cmd/Ctrl+Shift+F global search, tab
    // switching): never answer one.
    if (_modifierPressed()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final positionKey = widget.target.positionKey;
    if (positionKey == null || visible.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final start = _keyboard ? _focusedRow + step : _focusedRow;
      final next = start.clamp(0, visible.length - 1);
      setState(() {
        _keyboard = true;
        _focusedRow = next;
      });
      _controller.hover(positionKey, visible[next].uci);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) {
        final row = _focusedRow.clamp(0, visible.length - 1);
        _togglePin(visible[row].uci);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static bool _modifierPressed() {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(tobyPanelExpandedProvider, _onExpandedChanged);
    final expanded = ref.watch(tobyPanelExpandedProvider);
    final slots = TobyPanelSlots.of(context);
    final request = widget.target.request;
    TobyQuery? query;
    TobyReadingState? state;
    if (expanded && request != null) {
      final whatIf = _controller.whatIf;
      query = TobyQuery(
        request: request.copyWith(
          ratingOverride: whatIf.rating,
          cadenceOverride: whatIf.cadence,
        ),
        session: _controller.session,
      );
      final provider = tobyReadingProvider(query);
      state = ref.watch(provider);
      // The first position after the reader opens the panel is asked at
      // once; only position changes wait out the settle delay.
      if (_openedByReader) ref.read(provider.notifier).askNow();
    }
    if (expanded) _openedByReader = false;
    final reading = state?.reading;
    final visible =
        _visibleRows =
            expanded ? _visible(state, slots) : const <TobyCandidate>[];
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _onPanelKey(event),
      child: SizedBox(
        height: tobyPanelHeight(expanded: expanded, slots: slots),
        child: LayoutBuilder(
          builder:
              (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // One header in both states, so a keyboard toggle keeps
                  // its focus.
                  _TobyHeader(
                    expanded: expanded,
                    verdict: reading?.positionWdl,
                    onToggle: expanded ? _collapse : _open,
                  ),
                  if (expanded) ...[
                    SizedBox(
                      height: slots * _kRowHeight,
                      child: Focus(
                        focusNode: _rowsFocus,
                        // Tab passes over a slot area showing a message; a
                        // row that has focus keeps it while the next
                        // position loads.
                        skipTraversal: visible.isEmpty,
                        onKeyEvent: (_, event) => _onRowsKey(event, visible),
                        child: _slots(
                          state,
                          query,
                          slots: slots,
                          showWdl: constraints.maxWidth >= _kWdlMinPanelWidth,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: _kMetaHeight,
                      child: _meta(state, query, slots: slots),
                    ),
                    const SizedBox(
                      height: _kAttributionHeight,
                      child: _TobyAttribution(),
                    ),
                    const SizedBox(height: _kBottomPadding),
                  ],
                ],
              ),
        ),
      ),
    );
  }

  List<TobyCandidate> _visible(TobyReadingState? state, int slots) {
    final reading = state?.reading;
    if (widget.target.positionKey == null || reading == null) {
      return const <TobyCandidate>[];
    }
    return reading.candidates.take(slots).toList(growable: false);
  }

  Widget _slots(
    TobyReadingState? state,
    TobyQuery? query, {
    required int slots,
    required bool showWdl,
  }) {
    final idle = widget.target.idle;
    if (idle != null) return _TobyMessage(idle.message);
    if (state == null) return const _TobyMessage(_kThinking);
    final reading = state.reading;
    if (reading != null && reading.candidates.isNotEmpty) {
      return _rows(reading, slots: slots, showWdl: showWdl);
    }
    void retry() {
      if (query == null) return;
      ref.read(tobyReadingProvider(query).notifier).retry();
    }

    return switch (state.status) {
      TobyStatus.thinking ||
      TobyStatus.network => const _TobyMessage(_kThinking),
      TobyStatus.ready => const _TobyMessage('Toby sees no moves here'),
      TobyStatus.busy => _TobyMessage(_kBusy, onRetry: retry),
      TobyStatus.unavailable => _TobyMessage(
        'Toby is unavailable right now',
        onRetry: retry,
      ),
      TobyStatus.premiumUnconfirmed => _TobyMessage(
        "Premium couldn't be confirmed",
        onRetry: retry,
      ),
      TobyStatus.notApplicable => const _TobyMessage(
        "Toby can't read this position",
      ),
    };
  }

  Widget _rows(
    TobyReading reading, {
    required int slots,
    required bool showWdl,
  }) {
    final positionKey = widget.target.positionKey!;
    final visible = reading.candidates.take(slots).toList(growable: false);
    final hovered = _controller.hoveredUci(positionKey);
    final pinned = _controller.pinnedUci(positionKey);
    final focused =
        _keyboard && _rowsFocus.hasFocus && _focusedRow < visible.length
            ? visible[_focusedRow].uci
            : null;
    int? rowAt(Offset local) {
      final index = (local.dy / _kRowHeight).floor();
      return index >= 0 && index < visible.length ? index : null;
    }

    return MouseRegion(
      cursor: hovered != null ? SystemMouseCursors.click : MouseCursor.defer,
      onHover: (event) {
        final index = rowAt(event.localPosition);
        if (_keyboard) setState(() => _keyboard = false);
        _controller.hover(
          positionKey,
          index == null ? null : visible[index].uci,
        );
      },
      onExit: (_) => _controller.hover(positionKey, null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final index = rowAt(details.localPosition);
          if (index == null) return;
          _focusedRow = index;
          if (!_rowsFocus.hasFocus) {
            _focusByPointer = true;
            _rowsFocus.requestFocus();
          }
          _togglePin(visible[index].uci);
        },
        onSecondaryTapUp: (details) {
          final index = rowAt(details.localPosition);
          if (index == null) return;
          unawaited(_showRowMenu(visible[index], details.globalPosition));
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < slots; i++)
              SizedBox(
                height: _kRowHeight,
                child:
                    i < visible.length
                        ? _TobyRow(
                          key: ValueKey<String>(visible[i].uci),
                          candidate: visible[i],
                          muted: !reading.isFinal,
                          showWdl: showWdl,
                          lastSlot: i == slots - 1,
                          highlighted:
                              visible[i].uci == hovered ||
                              visible[i].uci == focused,
                          pinned: visible[i].uci == pinned,
                          onActivate: () => _togglePin(visible[i].uci),
                        )
                        : null,
              ),
          ],
        ),
      ),
    );
  }

  /// Whether the what-if menu can change anything: there is a position to
  /// read, Toby can read it, and the membership is confirmed.
  bool _whatIfApplies(TobyReadingState? state) =>
      widget.target.request != null &&
      state?.status != TobyStatus.notApplicable &&
      state?.status != TobyStatus.premiumUnconfirmed;

  /// The inputs row: how many moves the slots leave out (or a busy notice
  /// with Try again) on the left, the inputs Toby reads with on the right.
  /// Nothing in it is cut short: when both do not fit, the left side gives
  /// way to the inputs, and the inputs give way to a busy notice.
  Widget _meta(
    TobyReadingState? state,
    TobyQuery? query, {
    required int slots,
  }) {
    final reading = state?.reading;
    final busy =
        state?.status == TobyStatus.busy && reading != null && query != null;
    String? others;
    if (!busy && reading != null && widget.target.positionKey != null) {
      final hidden = reading.candidates.skip(slots);
      final count = hidden.length + reading.otherMoveCount;
      final chance = hidden.fold<double>(
        reading.otherProbability,
        (sum, candidate) => sum + candidate.probability,
      );
      if (count > 0) {
        others =
            '+$count ${count == 1 ? 'move' : 'moves'} · '
            '${tobyPercentage(chance)}';
      }
    }
    // Before the first reading, the inputs Gamebase will derive from the
    // request; never a placeholder.
    final inputs =
        query == null || !_whatIfApplies(state)
            ? null
            : (reading?.inputs ?? TobyInputs.expectedFor(query.request)).label;

    Widget busyNotice({required bool bounded}) {
      const notice = Text(
        _kBusy,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _kMetaStyle,
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (bounded) const Flexible(child: notice) else notice,
          const SizedBox(width: _kMetaGap),
          _TobyTextAction(
            label: _kTryAgain,
            fontSize: 11,
            onPress:
                () => ref.read(tobyReadingProvider(query!).notifier).retry(),
          ),
        ],
      );
    }

    Widget? left({required bool bounded}) =>
        busy
            ? busyNotice(bounded: bounded)
            : others == null
            ? null
            : Text(
              others,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _kMetaStyle,
            );

    Widget? right() =>
        inputs == null
            ? null
            // The popover owns its controller, so a menu left open when the
            // panel collapses goes with it.
            : FPopover(
              key: _whatIfKey,
              popoverAnchor: Alignment.bottomRight,
              childAnchor: Alignment.topRight,
              focusNode: _whatIfFocus,
              popoverBuilder:
                  (context, _) => _TobyWhatIfMenu(controller: _controller),
              builder:
                  (context, popover, _) => DesktopTooltip(
                    message: 'Read as other ratings or time controls',
                    child: _TobyTextAction(
                      label: inputs,
                      fontSize: 11,
                      emphasized: _controller.hasWhatIf,
                      onPress: () => _toggleWhatIf(popover),
                    ),
                  ),
            );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kContentInset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final actionStyle = _TobyTextAction.styleFor(11);
          final leftWidth =
              busy
                  ? _textWidth(context, _kBusy, _kMetaStyle) +
                      _kMetaGap +
                      _textWidth(context, _kTryAgain, actionStyle)
                  : others == null
                  ? null
                  : _textWidth(context, others, _kMetaStyle);
          final rightWidth =
              inputs == null ? null : _textWidth(context, inputs, actionStyle);
          // A pixel of slack for rounding between measuring and layout.
          final both =
              leftWidth != null &&
              rightWidth != null &&
              leftWidth + _kMetaGap + rightWidth + 1 <= constraints.maxWidth;
          final showLeft =
              leftWidth != null && (busy || rightWidth == null || both);
          final showRight = rightWidth != null && (!busy || both);
          if (showLeft && showRight) {
            return Row(
              children: [left(bounded: false)!, const Spacer(), right()!],
            );
          }
          if (showLeft) {
            return Align(
              alignment: Alignment.centerLeft,
              child: left(bounded: true),
            );
          }
          if (showRight) {
            return Align(alignment: Alignment.centerRight, child: right());
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

/// The window's root container. The board pane runs inside a per-tab scope,
/// and the window's paywall presenter is registered on the root.
ProviderContainer _windowContainer(BuildContext context) {
  var container = ProviderScope.containerOf(context, listen: false);
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is UncontrolledProviderScope) container = widget.container;
    return true;
  });
  return container;
}

/// The panel's top row, alone when collapsed. The sidebar's button look
/// (rounded 8, kWhiteColor70 to white, a kBlack3Color fill on hover) with
/// no nudge: nothing in the engine pane moves.
class _TobyHeader extends StatelessWidget {
  const _TobyHeader({
    required this.expanded,
    required this.onToggle,
    this.verdict,
  });

  final bool expanded;
  final VoidCallback onToggle;

  /// The position's outcome chances, shown after the label when expanded.
  final TobyWdl? verdict;

  @override
  Widget build(BuildContext context) {
    final verdict = this.verdict?.percentages;
    return SizedBox(
      height: _kHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _kListInset,
          vertical: 2,
        ),
        child: Semantics(
          expanded: expanded,
          child: FTappable.static(
            semanticsLabel: kTobyFeatureLabel,
            onPress: onToggle,
            style:
                (style) => style.copyWith(
                  cursor: const FWidgetStateMap({
                    WidgetState.any: SystemMouseCursors.click,
                  }),
                ),
            builder:
                (context, states, _) => SingleMotionBuilder(
                  value: states.contains(WidgetState.hovered) ? 1.0 : 0.0,
                  motion: DesktopMotion.hover,
                  builder: (context, value, _) {
                    final t = value.clamp(0.0, 1.0);
                    // The label is white while expanded; the chevron
                    // brightens with the hover either way.
                    final hover = Color.lerp(kWhiteColor70, kWhiteColor, t)!;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _kRowPadding,
                      ),
                      decoration: BoxDecoration(
                        color: kBlack3Color.withValues(
                          alpha: kBlack3Color.a * t,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _HeaderTitle(
                              labelColor: expanded ? kWhiteColor : hover,
                              verdict:
                                  expanded && verdict != null
                                      ? 'W ${verdict.white} · '
                                          'D ${verdict.draw} · '
                                          'B ${verdict.black}'
                                      : null,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            expanded
                                ? Icons.keyboard_arrow_down_rounded
                                : Icons.chevron_right_rounded,
                            size: 16,
                            color: hover,
                          ),
                        ],
                      ),
                    );
                  },
                ),
          ),
        ),
      ),
    );
  }
}

/// The feature's name, then the position verdict when it fits whole. The
/// name never gives way: a verdict without room is left out, not cut.
class _HeaderTitle extends StatelessWidget {
  const _HeaderTitle({required this.labelColor, required this.verdict});

  final Color labelColor;
  final String? verdict;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final verdict = this.verdict;
        final showVerdict =
            verdict != null &&
            _textWidth(context, kTobyFeatureLabel, _kLabelStyle) +
                    _kVerdictGap +
                    _textWidth(context, verdict, _kVerdictStyle) +
                    1 <=
                constraints.maxWidth;
        return Row(
          children: [
            Flexible(
              child: Text(
                kTobyFeatureLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _kLabelStyle.copyWith(color: labelColor),
              ),
            ),
            if (showVerdict) ...[
              const SizedBox(width: _kVerdictGap),
              Text(
                verdict,
                maxLines: 1,
                softWrap: false,
                style: _kVerdictStyle,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// One candidate: SAN under Stockfish's score column, the chance as a bar
/// (with Toby's first instinct marked when it differs), the percentage, and
/// how games tend to end after the move.
class _TobyRow extends StatelessWidget {
  const _TobyRow({
    super.key,
    required this.candidate,
    required this.muted,
    required this.showWdl,
    required this.lastSlot,
    required this.highlighted,
    required this.pinned,
    required this.onActivate,
  });

  final TobyCandidate candidate;

  /// The quick network stage: bars and text are muted until the final
  /// reading arrives.
  final bool muted;
  final bool showWdl;

  /// The inputs row, not another slot, lies below this one.
  final bool lastSlot;
  final bool highlighted;
  final bool pinned;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder:
          (context, constraints) => _build((
            width: constraints.maxWidth - 2 * _kListInset,
            height: lastSlot ? _kMetaHeight : _kRowHeight,
          )),
    );
  }

  /// [below] is the box of the row below, which the bars' tooltips take:
  /// as wide as this row's hover fill, as tall as that row.
  Widget _build(_RowBox below) {
    final textColor = muted ? kWhiteColor70 : kWhiteColor;
    final wdl = candidate.wdl;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kListInset),
      child: SingleMotionBuilder(
        value: highlighted || pinned ? 1.0 : 0.0,
        motion: DesktopMotion.hover,
        builder: (context, value, child) {
          final t = value.clamp(0.0, 1.0);
          // The pin outline is painted over the row, so it takes no room
          // and the SAN starts at the panel's content inset.
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: _kRowPadding),
            decoration: BoxDecoration(
              color: kBlack3Color.withValues(alpha: kBlack3Color.a * t),
              borderRadius: BorderRadius.circular(8),
            ),
            foregroundDecoration:
                pinned
                    ? BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: kTobyAccent.withValues(alpha: 0.45),
                      ),
                    )
                    : null,
            child: child,
          );
        },
        child: Row(
          children: [
            SizedBox(
              width: _kSanWidth,
              // A long promotion ("exd8=Q+") shrinks to the column rather
              // than losing its end.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  candidate.san,
                  maxLines: 1,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8 + _kPvFigureInset),
            Expanded(
              child: _ProbabilityBar(
                probability: candidate.probability,
                prior: candidate.priorDiffers ? candidate.prior : null,
                muted: muted,
                below: below,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: _kPercentWidth,
              child: Text(
                candidate.percentage,
                maxLines: 1,
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (showWdl) ...[
              const SizedBox(width: 8),
              _WdlBar(wdl: wdl, below: below),
            ],
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: pinned,
      label: tobyCandidateSemanticsLabel(candidate),
      excludeSemantics: true,
      onTap: onActivate,
      child: row,
    );
  }
}

/// "Nb3, 71 percent. After it: White 30, draw 55, Black 15".
@visibleForTesting
String tobyCandidateSemanticsLabel(TobyCandidate candidate) {
  final chance =
      candidate.probability > 0 && candidate.probability < .001
          ? 'under 0.1 percent'
          : '${_spokenPercent(candidate.probability)} percent';
  final wdl = candidate.wdl?.percentages;
  return wdl == null
      ? '${candidate.san}, $chance'
      : '${candidate.san}, $chance. After it: White ${wdl.white}, '
          'draw ${wdl.draw}, Black ${wdl.black}';
}

String _spokenPercent(double probability) {
  final tenths = (probability * 1000).round();
  return tenths % 10 == 0
      ? '${tenths ~/ 10}'
      : (tenths / 10).toStringAsFixed(1);
}

String _wholePercent(double probability) =>
    probability > 0 && probability < .005
        ? '<1%'
        : '${(probability * 100).round()}%';

/// The size of the row under a candidate.
typedef _RowBox = ({double width, double height});

/// A bar's tooltip, laid exactly over the row below (under the last slot,
/// the inputs row): it never covers the header or the row it explains, and
/// its edges fall between lines of text rather than through them. The text
/// sits at the row's inset, on the side of the bar it explains.
class _RowTip extends StatelessWidget {
  const _RowTip({
    required this.message,
    required this.below,
    required this.childStart,
    required this.child,
    this.alignEnd = false,
  });

  final String message;

  /// The row below, which the tip takes in full.
  final _RowBox below;

  /// Where [child] starts inside the row's box.
  final double childStart;
  final bool alignEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: message,
      tipAnchor: alignEnd ? Alignment.topRight : Alignment.topLeft,
      childAnchor: alignEnd ? Alignment.bottomRight : Alignment.bottomLeft,
      shift: (_, child, _) => Offset(-childStart, child.size.height),
      style:
          (style) => style.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: _kRowPadding),
            // The rows' corner at any height: forui's eases off below 24 px,
            // which squares the 22 px tip over the inputs row.
            decoration: style.decoration.copyWith(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
      tipBuilder:
          (context) => SizedBox(
            width: below.width - 2 * _kRowPadding,
            height: below.height,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment:
                  alignEnd ? Alignment.centerRight : Alignment.centerLeft,
              child: Text(
                message,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
      child: child,
    );
  }
}

class _ProbabilityBar extends StatelessWidget {
  const _ProbabilityBar({
    required this.probability,
    required this.prior,
    required this.muted,
    required this.below,
  });

  final double probability;

  /// Toby's first instinct, when it differs enough to mark.
  final double? prior;
  final bool muted;
  final _RowBox below;

  @override
  Widget build(BuildContext context) {
    // A size of its own, the row's height across the whole column: inside a
    // tooltip the bar sits in a loose stack and would otherwise collapse to
    // nothing. The full height also makes the tooltip easy to reach.
    final bar = SizedBox(
      width: double.infinity,
      height: _kRowHeight,
      child: CustomPaint(
        painter: _ProbabilityPainter(
          probability: probability,
          prior: prior,
          fill: kTobyAccent.withValues(alpha: muted ? _kNetworkAlpha : 1),
        ),
      ),
    );
    final instinct = prior;
    if (instinct == null) return bar;
    return _RowTip(
      message:
          'First instinct ${_wholePercent(instinct)} · after checking '
          '${_wholePercent(probability)}',
      below: below,
      // The bar starts after the row's padding, the SAN and its gap.
      childStart: _kRowPadding + _kSanWidth + 8 + _kPvFigureInset,
      child: bar,
    );
  }
}

class _ProbabilityPainter extends CustomPainter {
  const _ProbabilityPainter({
    required this.probability,
    required this.prior,
    required this.fill,
  });

  final double probability;
  final double? prior;
  final Color fill;

  static const double _barHeight = 6;
  static const double _markerHeight = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - _barHeight) / 2;
    const radius = Radius.circular(_barHeight / 2);
    final track = Rect.fromLTWH(0, top, size.width, _barHeight);
    // kDividerColor, so an empty track still reads against the panel.
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, radius),
      Paint()..color = kDividerColor,
    );
    final width = size.width * probability.clamp(0.0, 1.0);
    if (width > 0) {
      // A capsule of the fill's own width; a sliver narrower than the cap
      // is cut from a cap-wide capsule so it never reads past its value.
      canvas
        ..save()
        ..clipRect(Rect.fromLTWH(0, top, width, _barHeight))
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              0,
              top,
              width.clamp(_barHeight, size.width),
              _barHeight,
            ),
            radius,
          ),
          Paint()..color = fill,
        )
        ..restore();
    }
    final prior = this.prior;
    if (prior != null && size.width > 2) {
      final x = (size.width * prior.clamp(0.0, 1.0) - 1).clamp(
        0.0,
        size.width - 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - _markerHeight) / 2, 2, _markerHeight),
          const Radius.circular(1),
        ),
        Paint()..color = kWhiteColor70,
      );
    }
  }

  @override
  bool shouldRepaint(_ProbabilityPainter old) =>
      old.probability != probability || old.prior != prior || old.fill != fill;
}

/// White, draw and Black chances after one move, left to right. Until the
/// final reading they are unknown, and the column shows the empty track of
/// the probability bars.
class _WdlBar extends StatelessWidget {
  const _WdlBar({required this.wdl, required this.below});

  final TobyWdl? wdl;
  final _RowBox below;

  @override
  Widget build(BuildContext context) {
    final wdl = this.wdl;
    // Its own size, as for the probability bar: the tooltip's loose stack
    // would collapse a childless paint.
    final bar = SizedBox(
      width: _kWdlWidth,
      height: _kRowHeight,
      child: CustomPaint(painter: _WdlPainter(wdl)),
    );
    if (wdl == null) return bar;
    final whole = wdl.percentages;
    return _RowTip(
      message:
          'White ${whole.white} · draw ${whole.draw} · Black ${whole.black}',
      below: below,
      // The outcome bar ends at the row's padding.
      childStart: below.width - _kRowPadding - _kWdlWidth,
      alignEnd: true,
      child: bar,
    );
  }
}

class _WdlPainter extends CustomPainter {
  const _WdlPainter(this.wdl);

  final TobyWdl? wdl;

  static const double _barHeight = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - _barHeight) / 2;
    final bar = Rect.fromLTWH(0, top, size.width, _barHeight);
    const radius = Radius.circular(_barHeight / 2);
    final wdl = this.wdl;
    if (wdl == null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(bar, radius),
        Paint()..color = kDividerColor,
      );
      return;
    }
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(bar, radius));
    var x = 0.0;
    for (final (fraction, color) in [
      (wdl.white, _kWdlWhite),
      (wdl.draw, _kWdlDraw),
      (wdl.black, _kWdlBlack),
    ]) {
      final width = size.width * fraction;
      if (width <= 0) continue;
      final segment = Rect.fromLTWH(x, top, width, _barHeight);
      canvas.drawRect(segment, Paint()..color = color);
      if (width >= 2) {
        // A 1 px edge in the segment's own colour, lifted, so the dark
        // Black side still reads against the panel.
        canvas.drawRect(
          segment.deflate(0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Color.lerp(color, kWhiteColor, 0.18)!,
        );
      }
      x += width;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WdlPainter old) => old.wdl != wdl;
}

/// A non-data state, centred in the slot area and aligned with the rows.
/// A retry is its own control after the message, on the same line when it
/// fits; neither is ever cut short.
class _TobyMessage extends StatelessWidget {
  const _TobyMessage(this.message, {this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kContentInset),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              message,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            if (onRetry != null)
              _TobyTextAction(label: _kTryAgain, onPress: onRetry!),
          ],
        ),
      ),
    );
  }
}

/// A quiet text control: secondary text that turns white on hover.
class _TobyTextAction extends StatelessWidget {
  const _TobyTextAction({
    required this.label,
    required this.onPress,
    this.fontSize = 12,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback onPress;
  final double fontSize;

  /// Brighter at rest, for a what-if choice in effect.
  final bool emphasized;

  /// The label's style without its colour, for measuring.
  static TextStyle styleFor(double fontSize) => TextStyle(
    fontSize: fontSize,
    fontWeight: FontWeight.w600,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    return FTappable.static(
      onPress: onPress,
      style:
          (style) => style.copyWith(
            cursor: const FWidgetStateMap({
              WidgetState.any: SystemMouseCursors.click,
            }),
          ),
      builder:
          (context, states, _) => Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: styleFor(fontSize).copyWith(
              color:
                  states.contains(WidgetState.hovered)
                      ? kWhiteColor
                      : emphasized
                      ? kWhiteColor70
                      : kSecondaryTextColor,
            ),
          ),
    );
  }
}

/// Toby's licence attribution, verbatim, with its site linked.
class _TobyAttribution extends StatefulWidget {
  const _TobyAttribution();

  @override
  State<_TobyAttribution> createState() => _TobyAttributionState();
}

class _TobyAttributionState extends State<_TobyAttribution> {
  late final TapGestureRecognizer _open =
      TapGestureRecognizer()
        ..onTap = () {
          unawaited(launchDesktopWebUrl(Uri.parse(kTobyAttributionUrl)));
        };
  bool _hovered = false;

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefix = kTobyAttribution.substring(
      0,
      kTobyAttribution.length - kTobyAttributionLinkText.length,
    );
    const style = TextStyle(color: kSecondaryTextColor, fontSize: 11);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kContentInset),
      // A narrow rail shrinks the line instead of cutting the link off.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            style: style,
            children: [
              TextSpan(text: prefix),
              TextSpan(
                text: kTobyAttributionLinkText,
                recognizer: _open,
                mouseCursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                style: TextStyle(
                  color: _hovered ? kWhiteColor : kSecondaryTextColor,
                  decoration: TextDecoration.underline,
                  decorationColor: kSecondaryTextColor,
                ),
              ),
            ],
          ),
          maxLines: 1,
        ),
      ),
    );
  }
}

/// What-if choices for this board: both players' rating and the time
/// control. Kept for the board's lifetime, never saved.
class _TobyWhatIfMenu extends StatelessWidget {
  const _TobyWhatIfMenu({required this.controller});

  final TobyPanelController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final whatIf = controller.whatIf;
        return Container(
          width: 360,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kDividerColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _WhatIfLabel('Both players rated'),
              const SizedBox(height: 6),
              DesktopSegmentedTabs<int?>(
                wrap: true,
                selected: whatIf.rating,
                onChanged:
                    (rating) => controller.setWhatIf((
                      rating: rating,
                      cadence: whatIf.cadence,
                    )),
                tabs: [
                  const DesktopSegmentedTab<int?>(value: null, label: 'Game'),
                  for (final rating in kTobyRatingOverrides)
                    DesktopSegmentedTab<int?>(value: rating, label: '$rating'),
                ],
              ),
              const SizedBox(height: 14),
              const _WhatIfLabel('Time control'),
              const SizedBox(height: 6),
              DesktopSegmentedTabs<TobyCadence?>(
                wrap: true,
                selected: whatIf.cadence,
                onChanged:
                    (cadence) => controller.setWhatIf((
                      rating: whatIf.rating,
                      cadence: cadence,
                    )),
                tabs: [
                  const DesktopSegmentedTab<TobyCadence?>(
                    value: null,
                    label: 'Game',
                  ),
                  for (final cadence in TobyCadence.values)
                    DesktopSegmentedTab<TobyCadence?>(
                      value: cadence,
                      label: cadence.label,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WhatIfLabel extends StatelessWidget {
  const _WhatIfLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
