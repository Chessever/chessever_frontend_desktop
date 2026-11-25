/// "Toby Predicts": Toby's prediction of the move a human plays next, as
/// the engine pane's second tab beside Stockfish.
///
/// The pane's header carries two text tabs ([TobyViewTabs]), "Stockfish" and
/// "Toby Predicts", where the engine's name used to stand. Choosing Toby
/// puts [WhatTobyThinks] in the list area in place of Stockfish's lines,
/// drawn as Stockfish rows: the chance where the score sits, the move
/// where the line starts, and each row's own surface filled to the move's
/// chance, so the list reads as Toby's whole distribution at a glance. Over
/// the rows sit the inputs Toby read with (they open the what-if menu) and
/// the position's verdict; under them, every other move and Toby's
/// attribution. The view mounts only while its tab is shown, so Toby asks
/// nothing while Stockfish is. Everyone may read it, guests too: Gamebase
/// decides, and a refusal is one quiet notice in the view.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_guest_upgrade_dialog.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/services/toby/toby_access.dart';
import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/services/toby/toby_quality.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/widgets/cut_item_fade.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/utils/text_line_metrics.dart';
import 'package:chessever/theme/app_theme.dart';

// A Stockfish row's geometry, so Toby's list reads as the same list.

/// The Stockfish list's inset from the pane's sides.
const double _kListInset = 16;

/// A Stockfish row's 1 px border and the padding inside it.
const double _kRowPaddingX = 1 + 8;
const double _kRowPaddingY = 1 + 6;

/// Where a row's text starts, and every line over and under the rows.
const double _kContentInset = _kListInset + _kRowPaddingX;

/// Between rows, and under the list, as between Stockfish rows.
const double _kRowGap = 6;
const double _kListBottomPadding = 12;

/// Stockfish's score column (the chance stands in it) and the gap after it.
const double _kScoreWidth = 56;
const double _kScoreGap = 8;

/// Between the move and its first-instinct detail, and before the outcome
/// bar.
const double _kDetailGap = 8;

/// A Stockfish row's corner.
const double _kRowRadius = 4;

/// The reading line over the rows, and the space under it.
const double _kLeadHeight = 20;
const double _kLeadGap = 8;

/// Above the other-moves line, and between it and the attribution.
const double _kFooterGap = 10;
const double _kFooterLineGap = 4;

/// Between the list and the attribution while the rows scroll: more air
/// from the row the list's edge dissolves.
const double _kAttributionScrolledGap = 6;

/// The attribution's spacing in a pane with room for one row and nothing
/// more: it closes up under the row.
const double _kAttributionTightGap = 2;
const double _kAttributionTightBottom = 4;

/// Toby's attribution, under the list.
const TextStyle _kAttributionStyle = TextStyle(
  color: kSecondaryTextColor,
  fontSize: 11,
  height: 1.2,
);

/// The outcome bar after each move, and the taller box it is painted in.
const double _kWdlBarWidth = 40;
const double _kWdlBarHeight = 6;
const double _kWdlBarBoxHeight = 18;

/// Narrower than this, the outcome bars step aside (their numbers stay in
/// each row's semantics).
@visibleForTesting
const double kTobyWdlMinPanelWidth = 320;

/// Candidates listed: up to [_kMaxRows] moves of at least [_kMinRowChance],
/// and never fewer than [_kMinRows] (when the reading has that many). The
/// rest join the other-moves line.
const int _kMaxRows = 6;
const int _kMinRows = 3;
const double _kMinRowChance = 0.005;

/// Whole rows the view is sized for wherever the board's right rail can
/// spare the height ([WhatTobyThinks.comfortableHeight]).
const int _kComfortableRows = 3;

/// A row's surface fills to its chance in Toby's hue: a low tonal step off
/// the pane, never a bright bar. Lower still for the quick network stage.
const double _kFillAlpha = 0.13;
const double _kNetworkFillAlpha = 0.07;

/// White, draw and Black in the outcome bar.
const Color _kWdlWhite = Color(0xFFE8E6E1);
const Color _kWdlDraw = Color(0xFF8E8E93);
const Color _kWdlBlack = Color(0xFF3A3A3C);

/// A row's chance and fill for each move quality, on the pane's dark
/// surface (the desktop shell is dark only): light, desaturated tones of the
/// board arrows' hues ([tobyArrowHue]), each well clear of the row surface
/// for its 13 px chance. Neutral is Toby's teal.
const Color _kRowGood = Color(0xFF8CC4A0);
const Color _kRowDubious = Color(0xFFD9B77E);
const Color _kRowBad = Color(0xFFE0948C);

/// The tone of a row whose move is [quality].
@visibleForTesting
Color tobyRowTone(TobyMoveQuality quality) => switch (quality) {
  TobyMoveQuality.good => _kRowGood,
  TobyMoveQuality.dubious => _kRowDubious,
  TobyMoveQuality.bad => _kRowBad,
  TobyMoveQuality.neutral => kTobyAccent,
};

const String _kThinking = 'Toby is thinking…';
const String _kBusy = 'Toby is busy right now';
const String _kTryAgain = 'Try again';

/// Where the view's prompts say they came from.
const String _kGateSurface = 'engine_toby_tab';

/// Space between the pieces of the reading line, and the least space between
/// its left side and the verdict.
const double _kMetaGap = 8;
const double _kVerdictGap = 12;

const TextStyle _kChanceStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w700,
  fontFeatures: [FontFeature.tabularFigures()],
);
const TextStyle _kSanStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w600,
);
const TextStyle _kDetailStyle = TextStyle(
  color: kSecondaryTextColor,
  fontSize: 12,
  fontFeatures: [FontFeature.tabularFigures()],
);
const TextStyle _kVerdictStyle = TextStyle(
  color: kWhiteColor70,
  fontSize: 12,
  fontWeight: FontWeight.w500,
  fontFeatures: [FontFeature.tabularFigures()],
);
const TextStyle _kMetaStyle = TextStyle(
  color: kSecondaryTextColor,
  fontSize: 12,
  fontFeatures: [FontFeature.tabularFigures()],
);
const TextStyle _kMessageStyle = TextStyle(
  color: kWhiteColor70,
  fontSize: 12,
  height: 1.4,
);

/// The width [text] takes on one line in [style], laid out as a [Text]
/// here would lay it out.
double _textWidth(BuildContext context, String text, TextStyle style) =>
    desktopTextLineWidth(context, text, style);

/// A candidate row's height, as [_TobyRow] lays it out.
double _tobyRowExtent(BuildContext context, {required bool showBars}) {
  final line = math.max(
    desktopTextLineSize(context, '00.0%', _kChanceStyle).height,
    desktopTextLineSize(context, 'Bb5', _kSanStyle).height,
  );
  return 2 * _kRowPaddingY + math.max(line, showBars ? _kWdlBarBoxHeight : 0);
}

/// The attribution's line height.
double _tobyCreditLineHeight(BuildContext context) =>
    desktopTextLineSize(context, kTobyAttribution, _kAttributionStyle).height;

/// The candidates the view lists: up to six, each at least 0.5%, and never
/// fewer than the top three. Readings arrive most likely first.
@visibleForTesting
List<TobyCandidate> tobyListedCandidates(TobyReading reading) {
  final listed = <TobyCandidate>[];
  for (final candidate in reading.candidates) {
    if (listed.length >= _kMaxRows) break;
    if (listed.length >= _kMinRows &&
        candidate.probability < _kMinRowChance - 1e-9) {
      break;
    }
    listed.add(candidate);
  }
  return listed;
}

/// "24 other moves · 8.1%": every move [listed] leaves out, with their chance
/// together. Null when there is none.
@visibleForTesting
String? tobyOtherMovesLabel(TobyReading reading, int listed) {
  final hidden = reading.candidates.skip(listed);
  final count = hidden.length + reading.otherMoveCount;
  if (count <= 0) return null;
  final chance = hidden.fold<double>(
    reading.otherProbability,
    (sum, candidate) => sum + candidate.probability,
  );
  return '$count other ${count == 1 ? 'move' : 'moves'} · '
      '${tobyPercentage(chance)}';
}

/// "W 32 · D 48 · B 20", whole percentages that add up to 100.
@visibleForTesting
String tobyVerdictLabel(TobyWdl wdl) {
  final whole = wdl.percentages;
  return 'W ${whole.white} · D ${whole.draw} · B ${whole.black}';
}

/// Why the view reads nothing for the board's position.
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

/// What the board asks the view to read: a request for the position on the
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

/// Decides what the view of one board reads. [request] is only built when
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

/// The Toby Predicts tab's list area. The board pane builds it with an
/// immutable [target] and its own [controller]; the engine pane mounts it in
/// place of Stockfish's lines only while the tab is shown. It alone watches
/// Toby's reading, so nothing is asked while Stockfish is shown. While it is
/// mounted, the engine's arrows leave the board
/// ([TobyPanelController.holdsBoard]).
class WhatTobyThinks extends ConsumerStatefulWidget {
  const WhatTobyThinks({
    super.key,
    required this.target,
    required this.controller,
    this.onPlayUci,
  });

  final TobyTarget target;
  final TobyPanelController controller;

  /// The least height at which the view still shows one whole row and the
  /// attribution under it: its tightest step.
  static double leastHeight(BuildContext context) =>
      _tobyRowExtent(context, showBars: true) +
      _kAttributionTightGap +
      _tobyCreditLineHeight(context) +
      _kAttributionTightBottom;

  /// The height at which the view, [width] wide, shows its whole first
  /// step: the reading line, three whole rows and the attribution, with the
  /// rows ending on a whole row when more follow. It depends on the text
  /// metrics and the width alone, never on the reading, so the board's right
  /// rail can size the pane for it once per tab and keep that size while
  /// the reader moves through the game.
  static double comfortableHeight(
    BuildContext context, {
    required double width,
  }) {
    final rowExtent = _tobyRowExtent(
      context,
      showBars: width >= kTobyWdlMinPanelWidth,
    );
    return _kLeadHeight +
        _kLeadGap +
        _kComfortableRows * rowExtent +
        (_kComfortableRows - 1) * _kRowGap +
        _kAttributionScrolledGap +
        _tobyCreditLineHeight(context) +
        _kListBottomPadding;
  }

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
  List<TobyCandidate> _listed = const <TobyCandidate>[];

  /// An Esc that cleared the pin also owns its key repeats, so holding it
  /// cannot go on to close the tab.
  bool _escapeConsumed = false;

  /// The reader just chose the tab (the view mounts with it): the first
  /// request goes out at once, with no navigation to settle.
  bool _askNow = true;

  /// The what-if menu keeps its state while the reading line rearranges
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
      oldWidget.controller
        ..removeListener(_onControllerChanged)
        ..holdBoardSoon(false)
        ..showReadingSoon(null, null)
        ..clearMarksSoon();
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
    // Leaving the tab (or the pane: picture-in-picture, a closed board)
    // gives the board back its engine arrows, and no Toby arrow outlives
    // the view that drew it.
    _controller
      ..holdBoardSoon(false)
      ..showReadingSoon(null, null)
      ..clearMarksSoon();
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
    final listed = _listed;
    if (!mounted || positionKey == null || listed.isEmpty) return;
    final row = _focusedRow.clamp(0, listed.length - 1);
    setState(() {
      _keyboard = true;
      _focusedRow = row;
    });
    _controller.hover(positionKey, listed[row].uci);
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

  void _togglePin(String uci) {
    final positionKey = widget.target.positionKey;
    if (positionKey == null) return;
    _controller.togglePin(positionKey, uci);
  }

  void _hoverRow(String positionKey, String uci) {
    if (_keyboard) setState(() => _keyboard = false);
    _controller.hover(positionKey, uci);
  }

  void _pressRow(int index, String uci) {
    _focusedRow = index;
    if (!_rowsFocus.hasFocus) {
      _focusByPointer = true;
      _rowsFocus.requestFocus();
    }
    _togglePin(uci);
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

  /// Esc anywhere inside the view (rows, reading line, what-if menu). It
  /// closes the board tab elsewhere, so it means "unpin" here only while
  /// there is a pin to clear; otherwise it passes on.
  KeyEventResult _onViewKey(KeyEvent event) {
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

  /// Up/Down walk the candidates, Enter pins one. Everything else (←/→ step
  /// the game, Space, Esc without a pin) passes on to the rail.
  KeyEventResult _onRowsKey(KeyEvent event, List<TobyCandidate> listed) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // Chords belong to the shell (Cmd/Ctrl+Shift+F global search, tab
    // switching): never answer one.
    if (_modifierPressed()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final positionKey = widget.target.positionKey;
    if (positionKey == null || listed.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final start = _keyboard ? _focusedRow + step : _focusedRow;
      final next = start.clamp(0, listed.length - 1);
      setState(() {
        _keyboard = true;
        _focusedRow = next;
      });
      _controller.hover(positionKey, listed[next].uci);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) {
        final row = _focusedRow.clamp(0, listed.length - 1);
        _togglePin(listed[row].uci);
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
    // While the view is on screen in place of Stockfish's lines, the
    // engine's arrows leave the board; leaving gives them back (dispose).
    _controller.holdBoardSoon(true);
    final request = widget.target.request;
    TobyQuery? query;
    TobyReadingState? state;
    if (request != null) {
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
      // The first position after the reader chooses the tab is asked at
      // once; only position changes wait out the settle delay.
      if (_askNow) ref.read(provider.notifier).askNow();
    }
    _askNow = false;
    final reading = widget.target.positionKey == null ? null : state?.reading;
    final listed =
        _listed =
            reading == null || reading.candidates.isEmpty
                ? const <TobyCandidate>[]
                : tobyListedCandidates(reading);
    // The board draws the reading's top three while nothing is hovered or
    // pinned. Through the controller, so only the board hears it.
    _controller.showReadingSoon(widget.target.positionKey, reading);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _onViewKey(event),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final showBars = width >= kTobyWdlMinPanelWidth;
          final rowExtent = _tobyRowExtent(context, showBars: showBars);
          final creditLine = _tobyCreditLineHeight(context);
          final scrolledCredit =
              _kAttributionScrolledGap + creditLine + _kListBottomPadding;
          const leadExtent = _kLeadHeight + _kLeadGap;
          final roomForLead = height >= leadExtent + rowExtent + scrolledCredit;
          final busy =
              state?.status == TobyStatus.busy &&
              reading != null &&
              query != null;
          // A busy notice over a kept network stage needs its line (it
          // carries Try again). A pane too short for that line, a whole row
          // and the attribution shows the notice alone, as it does with no
          // stage kept.
          if (listed.isEmpty || (busy && !roomForLead)) {
            final lead = _lead(
              context,
              state,
              query,
              listed.isEmpty ? reading : null,
              width: width,
            );
            return DesktopScrollHost(
              child: CustomScrollView(
                physics: const DesktopScrollPhysics(),
                slivers: [
                  if (lead != null) SliverToBoxAdapter(child: lead),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        _kContentInset,
                        0,
                        _kContentInset,
                        _kListBottomPadding,
                      ),
                      child: Center(child: _message(state, query)),
                    ),
                  ),
                ],
              ),
            );
          }
          // The attribution stays on screen under the rows at any height:
          // the rows scroll above it. A short pane gives way in fixed steps,
          // so one whole row and the attribution always fit together:
          //  1. everything (the reading line, the rows, the attribution);
          //  2. the reading line steps aside;
          //  3. the attribution closes up under the one row.
          final tight = height < rowExtent + scrolledCredit;
          final lead =
              roomForLead
                  ? _lead(context, state, query, reading, width: width)
                  : null;
          final others = tobyOtherMovesLabel(reading!, listed.length);
          // Where each item of the list starts and ends (the rows, then the
          // other-moves line), under the reading line.
          final items = <(double, double)>[];
          var y = lead == null ? 0.0 : leadExtent;
          for (var i = 0; i < listed.length; i++) {
            items.add((y, y + rowExtent));
            y += rowExtent + _kRowGap;
          }
          if (others != null) {
            final top = items.last.$2 + _kFooterGap;
            items.add((
              top,
              top + desktopTextLineSize(context, others, _kMetaStyle).height,
            ));
          }
          // Whether the rows outrun the pane and scroll. The list then ends
          // on a whole row when the next one would barely show (it is the
          // row under the edge that dissolves into the pane only when most
          // of it is on screen), and the attribution keeps more air from it.
          var room = height - scrolledCredit;
          final scrolls = items.last.$2 > room + 0.5;
          if (scrolls) {
            for (var i = 1; i < items.length; i++) {
              final (top, bottom) = items[i];
              if (bottom <= room + 0.5) continue;
              if (room - top < (bottom - top) * CutItemFade.minVisibleShare) {
                room = items[i - 1].$2;
              }
              break;
            }
          }
          final Widget list = CutItemFade(
            child: DesktopScrollHost(
              child: CustomScrollView(
                shrinkWrap: true,
                physics: const DesktopScrollPhysics(),
                slivers: [
                  if (lead != null) SliverToBoxAdapter(child: lead),
                  SliverToBoxAdapter(
                    child: _rows(reading, listed, showBars: showBars),
                  ),
                  if (others != null)
                    SliverToBoxAdapter(child: _otherMoves(others)),
                ],
              ),
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // As tall as the rows need, up to the room the attribution
              // leaves; then the rows scroll, and the row the edge cuts
              // dissolves into the pane.
              if (height.isFinite)
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: scrolls && !tight ? room : double.infinity,
                    ),
                    child: list,
                  ),
                )
              else
                list,
              Padding(
                padding: EdgeInsets.fromLTRB(
                  _kContentInset,
                  tight
                      ? _kAttributionTightGap
                      : scrolls
                      ? _kAttributionScrolledGap
                      : _kFooterLineGap,
                  _kContentInset,
                  tight ? _kAttributionTightBottom : _kListBottomPadding,
                ),
                child: const _TobyAttribution(),
              ),
            ],
          );
        },
      ),
    );
  }

  /// One centred line for every state without rows.
  Widget _message(TobyReadingState? state, TobyQuery? query) {
    final idle = widget.target.idle;
    if (idle != null) return _TobyMessage(idle.message);
    if (state == null) return const _TobyMessage(_kThinking);
    void retry() {
      if (query == null || !mounted) return;
      ref.read(tobyReadingProvider(query).notifier).retry();
    }

    // Gamebase refused the reading: its access setting is stricter than the
    // client's (which lets everyone in). The window's prompts carry the
    // action; a reader who completes one is asked about again.
    void upgrade() => unawaited(
      presentTobyServerGate(
        _windowContainer(context),
        surface: _kGateSurface,
        resume: DesktopAccessResume(run: retry, stillMatches: () => mounted),
      ),
    );
    Future<void> signIn() async {
      final signedIn = await showDesktopAccountSignIn(
        context,
        surface: _kGateSurface,
        title: 'Sign in to see $kTobyFeatureLabel',
        message: 'Toby reads positions for signed-in accounts right now.',
      );
      if (signedIn) retry();
    }

    // Gamebase did not accept a signed-in reader's session (an expired
    // token, say): signing in again is not the answer, asking again is.
    final hasAccount = ref.watch(
      desktopEntitlementProvider.select(
        (snapshot) => snapshot.hasPermanentAccount,
      ),
    );

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
      TobyStatus.premiumRequired => _TobyMessage(
        '$kTobyFeatureLabel is Premium right now',
        action: 'Upgrade',
        onRetry: upgrade,
      ),
      TobyStatus.signInRequired =>
        hasAccount
            ? _TobyMessage("Couldn't confirm your account", onRetry: retry)
            : _TobyMessage(
              'An account is needed right now',
              action: 'Sign in',
              onRetry: () => unawaited(signIn()),
            ),
      TobyStatus.notApplicable => const _TobyMessage(
        "Toby can't read this position",
      ),
    };
  }

  Widget _rows(
    TobyReading reading,
    List<TobyCandidate> listed, {
    required bool showBars,
  }) {
    final positionKey = widget.target.positionKey!;
    final qualities = tobyMoveQualities(reading);
    final hovered = _controller.hoveredUci(positionKey);
    final pinned = _controller.pinnedUci(positionKey);
    final focused =
        _keyboard && _rowsFocus.hasFocus && _focusedRow < listed.length
            ? listed[_focusedRow].uci
            : null;
    return Focus(
      focusNode: _rowsFocus,
      onKeyEvent: (_, event) => _onRowsKey(event, listed),
      child: MouseRegion(
        // Off the rows, the board shows the pin (or the engine's view)
        // again.
        onExit: (_) => _controller.hover(positionKey, null),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _kListInset),
          child: CutFadeItems(
            gap: _kRowGap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < listed.length; i++)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => _hoverRow(positionKey, listed[i].uci),
                    onHover: (_) => _hoverRow(positionKey, listed[i].uci),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _pressRow(i, listed[i].uci),
                      onSecondaryTapUp:
                          (details) => unawaited(
                            _showRowMenu(listed[i], details.globalPosition),
                          ),
                      // A gap belongs to the row above it, so the pointer never
                      // falls between two rows and the board never flickers
                      // back to the engine's view.
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: i == listed.length - 1 ? 0 : _kRowGap,
                        ),
                        child: _TobyRow(
                          key: ValueKey<String>(listed[i].uci),
                          candidate: listed[i],
                          quality:
                              qualities[listed[i].uci] ??
                              TobyMoveQuality.neutral,
                          muted: !reading.isFinal,
                          showBar: showBars,
                          highlighted:
                              listed[i].uci == hovered ||
                              listed[i].uci == focused,
                          pinned: listed[i].uci == pinned,
                          onActivate: () => _togglePin(listed[i].uci),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Under the rows: every move they leave out ("24 other moves · 8.1%").
  Widget _otherMoves(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _kContentInset,
        _kFooterGap,
        _kContentInset,
        0,
      ),
      child: CutFadeItems(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: _kMetaStyle,
            ),
          ],
        ),
      ),
    );
  }

  /// Whether the what-if menu can change anything: there is a position to
  /// read, Toby can read it, and Gamebase has not refused the reader.
  bool _whatIfApplies(TobyReadingState? state) =>
      widget.target.request != null &&
      switch (state?.status) {
        TobyStatus.notApplicable ||
        TobyStatus.premiumUnconfirmed ||
        TobyStatus.premiumRequired ||
        TobyStatus.signInRequired => false,
        _ => true,
      };

  /// The reading line over the rows: the inputs Toby reads with (they open
  /// the what-if menu), or a busy notice with Try again over a network stage
  /// it kept, on the left; the position's verdict on the right. Nothing in
  /// it is cut short: when both do not fit, the verdict steps aside. Null
  /// when there is nothing to say.
  Widget? _lead(
    BuildContext context,
    TobyReadingState? state,
    TobyQuery? query,
    TobyReading? reading, {
    required double width,
  }) {
    final busy =
        state?.status == TobyStatus.busy && reading != null && query != null;
    // Before the first reading, the inputs Gamebase will derive from the
    // request; never a placeholder.
    final inputs =
        busy || query == null || !_whatIfApplies(state)
            ? null
            : (reading?.inputs ?? TobyInputs.expectedFor(query.request)).label;
    final wdl = reading?.positionWdl;
    final verdict = wdl == null ? null : tobyVerdictLabel(wdl);
    if (!busy && inputs == null && verdict == null) return null;

    final room = width - 2 * _kContentInset;
    final leftWidth =
        busy
            ? _textWidth(context, _kBusy, _kMetaStyle) +
                _kMetaGap +
                _textWidth(context, _kTryAgain, _TobyTextAction.strongStyle)
            : inputs == null
            ? 0.0
            : _textWidth(context, inputs, _TobyTextAction.style);
    // A pixel of slack for rounding between measuring and layout.
    final showVerdict =
        verdict != null &&
        (leftWidth == 0 ? 0 : leftWidth + _kVerdictGap) +
                _textWidth(context, verdict, _kVerdictStyle) +
                1 <=
            room;

    Widget busyNotice() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Flexible(
          child: Text(
            _kBusy,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _kMetaStyle,
          ),
        ),
        const SizedBox(width: _kMetaGap),
        _TobyTextAction(
          label: _kTryAgain,
          strong: true,
          onPress: () => ref.read(tobyReadingProvider(query!).notifier).retry(),
        ),
      ],
    );

    Widget whatIf(String label) => FPopover(
      key: _whatIfKey,
      popoverAnchor: Alignment.topLeft,
      childAnchor: Alignment.bottomLeft,
      focusNode: _whatIfFocus,
      popoverBuilder: (context, _) => _TobyWhatIfMenu(controller: _controller),
      builder:
          (context, popover, _) => DesktopTooltip(
            message: 'Read as other ratings or time controls',
            child: _TobyTextAction(
              label: label,
              emphasized: _controller.hasWhatIf,
              onPress: () => _toggleWhatIf(popover),
            ),
          ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _kContentInset,
        0,
        _kContentInset,
        _kLeadGap,
      ),
      child: SizedBox(
        height: _kLeadHeight,
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child:
                    busy
                        ? busyNotice()
                        : inputs == null
                        ? const SizedBox.shrink()
                        : whatIf(inputs),
              ),
            ),
            if (showVerdict)
              DesktopTooltip(
                message: 'How games tend to end from here',
                child: Text(
                  verdict,
                  maxLines: 1,
                  softWrap: false,
                  style: _kVerdictStyle,
                ),
              ),
          ],
        ),
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

/// "Nb3, 71 percent, first instinct 64 percent, a mistake. After it: White
/// 30, draw 55, Black 15". The first instinct is spoken when the row shows
/// it, and the move's [quality] when it is dubious or a mistake (a good
/// move's colour says nothing worth a word).
@visibleForTesting
String tobyCandidateSemanticsLabel(
  TobyCandidate candidate, {
  TobyMoveQuality quality = TobyMoveQuality.neutral,
}) {
  String spoken(double probability) =>
      probability > 0 && probability < .001
          ? 'under 0.1 percent'
          : '${_spokenPercent(probability)} percent';
  final prior = candidate.prior;
  final instinct =
      prior != null && candidate.priorDiffers
          ? ', first instinct ${spoken(prior)}'
          : '';
  final judged = tobyQualitySpoken(quality);
  final verdict = judged.isEmpty ? '' : ', $judged';
  final wdl = candidate.wdl?.percentages;
  return wdl == null
      ? '${candidate.san}, ${spoken(candidate.probability)}$instinct$verdict'
      : '${candidate.san}, ${spoken(candidate.probability)}$instinct$verdict. '
          'After it: White ${wdl.white}, draw ${wdl.draw}, Black ${wdl.black}';
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

/// One candidate, as a Stockfish row: the chance in the score column, then
/// the move with Toby's first instinct when it differs by five points or
/// more, and the outcome bar at the end. The row's own surface fills to its
/// chance; the hover fill and the pin's edge compose over it. The chance and
/// the fill take the move's [quality] tone, as its arrow on the board does.
class _TobyRow extends StatelessWidget {
  const _TobyRow({
    super.key,
    required this.candidate,
    required this.quality,
    required this.muted,
    required this.showBar,
    required this.highlighted,
    required this.pinned,
    required this.onActivate,
  });

  final TobyCandidate candidate;
  final TobyMoveQuality quality;

  /// The quick network stage: fills and text are muted until the final
  /// reading replaces them in place.
  final bool muted;

  /// Whether the pane is wide enough for the outcome bar.
  final bool showBar;
  final bool highlighted;
  final bool pinned;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final prior = candidate.prior;
    final tone = tobyRowTone(quality);
    final content = Row(
      children: [
        _Chance(
          candidate.percentage,
          color: muted ? tone.withValues(alpha: 0.6) : tone,
        ),
        const SizedBox(width: _kScoreGap),
        Expanded(
          child: _RowLine(
            san: candidate.san,
            sanColor: muted ? kWhiteColor70 : kWhiteColor,
            instinct:
                !muted && prior != null && candidate.priorDiffers
                    ? 'first instinct ${_wholePercent(prior)}'
                    : null,
          ),
        ),
        if (showBar) ...[
          const SizedBox(width: _kDetailGap),
          _WdlBar(wdl: muted ? null : candidate.wdl),
        ],
      ],
    );
    return Semantics(
      button: true,
      selected: pinned,
      label: tobyCandidateSemanticsLabel(candidate, quality: quality),
      excludeSemantics: true,
      onTap: onActivate,
      child: SingleMotionBuilder(
        value: highlighted ? 1.0 : 0.0,
        motion: DesktopMotion.hover,
        builder:
            (context, value, child) => CustomPaint(
              painter: _TobyRowPainter(
                chance: candidate.probability,
                fill: tone.withValues(
                  alpha: muted ? _kNetworkFillAlpha : _kFillAlpha,
                ),
                hover: value.clamp(0.0, 1.0),
                pinned: pinned,
              ),
              child: child,
            ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _kRowPaddingX,
            vertical: _kRowPaddingY,
          ),
          child: content,
        ),
      ),
    );
  }
}

/// A chance in the score column. Chances end on one edge, the width of
/// "00.0%" from the column's start, so their decimal points stand in a
/// column and a two-figure chance starts where a Stockfish score does.
class _Chance extends StatelessWidget {
  const _Chance(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final edge = _textWidth(
      context,
      '00.0%',
      _kChanceStyle,
    ).ceilToDouble().clamp(0.0, _kScoreWidth);
    return SizedBox(
      width: _kScoreWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: edge,
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textAlign: TextAlign.end,
            style: _kChanceStyle.copyWith(color: color),
          ),
        ),
      ),
    );
  }
}

/// A row's line: the move, then Toby's first instinct when it differs.
/// Nothing in it is cut: a long promotion shrinks into the room it has, and
/// an instinct without room steps aside (it stays in the row's semantics).
class _RowLine extends StatelessWidget {
  const _RowLine({required this.san, required this.sanColor, this.instinct});

  final String san;
  final Color sanColor;
  final String? instinct;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final instinct = this.instinct;
        final showInstinct =
            instinct != null &&
            _textWidth(context, san, _kSanStyle) +
                    _kDetailGap +
                    _textWidth(context, instinct, _kDetailStyle) +
                    1 <=
                constraints.maxWidth;
        return Row(
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  san,
                  maxLines: 1,
                  style: _kSanStyle.copyWith(color: sanColor),
                ),
              ),
            ),
            if (showInstinct) ...[
              const SizedBox(width: _kDetailGap),
              Text(
                instinct,
                maxLines: 1,
                softWrap: false,
                style: _kDetailStyle,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// How games tend to end after a move: White, draw and Black, left to right,
/// in a 40 x 6 bar, with the figures in its tooltip. Until the final reading
/// the outcome is unknown and the bar is an empty track.
class _WdlBar extends StatelessWidget {
  const _WdlBar({required this.wdl});

  final TobyWdl? wdl;

  @override
  Widget build(BuildContext context) {
    final wdl = this.wdl;
    // Taller than the bar, so the tooltip is easy to reach; the bar is
    // painted at its centre.
    final bar = SizedBox(
      width: _kWdlBarWidth,
      height: _kWdlBarBoxHeight,
      child: CustomPaint(painter: _WdlPainter(wdl)),
    );
    if (wdl == null) return bar;
    final whole = wdl.percentages;
    return DesktopTooltip(
      message:
          'White ${whole.white} · draw ${whole.draw} · Black ${whole.black}',
      child: bar,
    );
  }
}

class _WdlPainter extends CustomPainter {
  const _WdlPainter(this.wdl);

  final TobyWdl? wdl;

  @override
  void paint(Canvas canvas, Size size) {
    final top = ((size.height - _kWdlBarHeight) / 2).roundToDouble();
    final capsule = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, _kWdlBarHeight),
      const Radius.circular(_kWdlBarHeight / 2),
    );
    final wdl = this.wdl;
    if (wdl == null) {
      canvas.drawRRect(capsule, Paint()..color = kDividerColor);
    } else {
      canvas
        ..save()
        ..clipRRect(capsule);
      var x = 0.0;
      for (final (fraction, color) in [
        (wdl.white, _kWdlWhite),
        (wdl.draw, _kWdlDraw),
        (wdl.black, _kWdlBlack),
      ]) {
        final width = size.width * fraction;
        if (width <= 0) continue;
        canvas.drawRect(
          Rect.fromLTWH(x, top, width, _kWdlBarHeight),
          Paint()..color = color,
        );
        x += width;
      }
      canvas.restore();
    }
    // A hairline lip in white, so the dark Black end (and the empty track)
    // still reads against the pane and the hover fill.
    canvas.drawRRect(
      capsule.deflate(0.25),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = kWhiteColor.withValues(alpha: 0.16),
    );
  }

  @override
  bool shouldRepaint(_WdlPainter old) => old.wdl != wdl;
}

/// A Toby row's surface: a Stockfish row's hover fill (hovered or pinned),
/// the row's chance as a tonal fill from its left edge over it (the row
/// itself is the bar), and a Stockfish row's 1 px edge while hovered, or
/// Toby's while pinned.
class _TobyRowPainter extends CustomPainter {
  const _TobyRowPainter({
    required this.chance,
    required this.fill,
    this.hover = 0,
    this.pinned = false,
  });

  final double chance;
  final Color fill;
  final double hover;
  final bool pinned;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(_kRowRadius),
    );
    // A Stockfish row's hover fill, also under a pinned row.
    final lift = pinned ? 1.0 : hover;
    if (lift > 0) {
      canvas.drawRRect(
        box,
        Paint()..color = kBlack3Color.withValues(alpha: kBlack3Color.a * lift),
      );
    }
    final width = (size.width * chance.clamp(0.0, 1.0)).roundToDouble();
    if (width > 0) {
      canvas
        ..save()
        ..clipRRect(box)
        ..drawRect(
          Rect.fromLTWH(0, 0, width, size.height),
          Paint()..color = fill,
        )
        ..restore();
    }
    final edge =
        pinned
            ? Color.lerp(
              kTobyAccent.withValues(alpha: 0.5),
              kPrimaryColor.withValues(alpha: 0.4),
              hover,
            )!
            : kPrimaryColor.withValues(alpha: 0.4 * hover);
    if (edge.a > 0) {
      canvas.drawRRect(
        box.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = edge,
      );
    }
  }

  @override
  bool shouldRepaint(_TobyRowPainter old) =>
      old.chance != chance ||
      old.fill != fill ||
      old.hover != hover ||
      old.pinned != pinned;
}

/// A state without rows, as one line centred in the list area. A retry is
/// its own control after the message, on the same line when it fits;
/// neither is ever cut short.
class _TobyMessage extends StatelessWidget {
  const _TobyMessage(this.message, {this.onRetry, this.action = _kTryAgain});

  final String message;

  /// The control after the message ("Try again", "Upgrade", "Sign in").
  final VoidCallback? onRetry;
  final String action;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      runAlignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        Text(message, textAlign: TextAlign.center, style: _kMessageStyle),
        if (onRetry != null)
          _TobyTextAction(label: action, strong: true, onPress: onRetry!),
      ],
    );
  }
}

/// A text control. Quiet ones (the inputs that open the what-if menu) are
/// secondary text that turns white under the pointer. [strong] ones (the one
/// action of a notice: Try again, Upgrade, Sign in) are the brightest text on
/// their line, at full weight, and take Toby's teal under the pointer.
class _TobyTextAction extends StatelessWidget {
  const _TobyTextAction({
    required this.label,
    required this.onPress,
    this.emphasized = false,
    this.strong = false,
  });

  final String label;
  final VoidCallback onPress;

  /// Brighter at rest, for a what-if choice in effect.
  final bool emphasized;

  /// A notice's action.
  final bool strong;

  /// The labels' styles without their colour, for measuring.
  static const TextStyle style = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const TextStyle strongStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
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
      builder: (context, states, _) {
        final hovered = states.contains(WidgetState.hovered);
        return Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (strong ? strongStyle : style).copyWith(
            color:
                strong
                    ? (hovered ? kTobyAccent : kWhiteColor)
                    : hovered
                    ? kWhiteColor
                    : emphasized
                    ? kWhiteColor70
                    : kSecondaryTextColor,
          ),
        );
      },
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
    // A narrow rail shrinks the line instead of cutting the link off.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          style: _kAttributionStyle,
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

/// The engine pane's two tabs, in its header where the engine's name stood:
/// "Stockfish" and "Toby Predicts". The chosen tab is set in white at full
/// weight; the other in 70% white until the pointer reaches it. A static
/// 2 px rule under the chosen label, as wide as the label, marks it too.
/// Nothing moves on hover or on a switch: each tab keeps the width of its
/// full-weight label, and the two hit areas meet between the labels.
///
/// Both tabs are open to everyone, with no lock and no prompt: Gamebase
/// decides who may read Toby. Tabs take focus with Tab and switch with Enter
/// or Space; arrows, Esc and modifier chords pass on to the board.
class TobyViewTabs extends ConsumerStatefulWidget {
  const TobyViewTabs({super.key, this.compact = false});

  /// A narrow header's tabs: the labels 10 px apart instead of 16, and no
  /// room after the last one. The labels keep their size.
  final bool compact;

  /// The engine's tab.
  static const String stockfishLabel = 'Stockfish';

  /// The room before the first label, part of its hit area. The header
  /// subtracts it from the gap before the tabs, so the first label sits
  /// where the engine's name did.
  static const double labelInset = _kTabEdge;

  /// The tabs' width on one line, so the header can tell what fits beside
  /// them.
  static double widthOf(BuildContext context, {bool compact = false}) {
    final gap = compact ? _kCompactTabGap : _kTabGap;
    return _TobyTab.labelWidth(context, stockfishLabel) +
        _TobyTab.labelWidth(context, kTobyFeatureLabel) +
        _kTabEdge +
        gap +
        (compact ? 0 : _kTabEdge);
  }

  @override
  ConsumerState<TobyViewTabs> createState() => _TobyViewTabsState();
}

/// Room before the first label and after the last.
const double _kTabEdge = 6;

/// Between the two labels, split between the two hit areas.
const double _kTabGap = 16;
const double _kCompactTabGap = 10;

class _TobyViewTabsState extends ConsumerState<TobyViewTabs> {
  /// Open to everyone, guests included: Gamebase decides who may read, and
  /// a refusal is a notice in the view, never a gate here.
  void _chooseToby() {
    if (!mounted || ref.read(tobyTabSelectedProvider)) return;
    ref.read(tobyTabPreferenceProvider.notifier).choose(true);
  }

  void _chooseStockfish() {
    if (!ref.read(tobyTabSelectedProvider)) return;
    ref.read(tobyTabPreferenceProvider.notifier).choose(false);
  }

  @override
  Widget build(BuildContext context) {
    final toby = ref.watch(tobyTabSelectedProvider);
    final half = (widget.compact ? _kCompactTabGap : _kTabGap) / 2;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TobyTab(
            label: TobyViewTabs.stockfishLabel,
            selected: !toby,
            onPress: _chooseStockfish,
            padding: EdgeInsets.only(left: _kTabEdge, right: half),
          ),
          _TobyTab(
            label: kTobyFeatureLabel,
            selected: toby,
            onPress: _chooseToby,
            padding: EdgeInsets.only(
              left: half,
              right: widget.compact ? 0 : _kTabEdge,
            ),
          ),
        ],
      ),
    );
  }
}

/// One tab of [TobyViewTabs]: a text label, white at full weight when
/// chosen, 70% white (white under the pointer) when not.
class _TobyTab extends StatelessWidget {
  const _TobyTab({
    required this.label,
    required this.selected,
    required this.onPress,
    required this.padding,
  });

  final String label;
  final bool selected;
  final VoidCallback onPress;

  /// The hit area around the label.
  final EdgeInsets padding;

  /// The header's control height.
  static const double _height = 28;

  /// The rule under the chosen label, and its distance from the hit area's
  /// bottom edge.
  static const double _ruleHeight = 2;
  static const double _ruleInset = 1;

  static const TextStyle _style = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  /// The label's width at full weight, which the tab keeps in both states.
  static double labelWidth(BuildContext context, String label) =>
      _textWidth(context, label, _style).ceilToDouble();

  @override
  Widget build(BuildContext context) {
    final width = labelWidth(context, label);
    return FTappable.static(
      semanticsLabel: label,
      excludeSemantics: true,
      selected: selected,
      behavior: HitTestBehavior.opaque,
      onPress: onPress,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      // Keyboard focus only: a click never moves focus to a tab.
      focusedOutlineStyle:
          (_) => FFocusedOutlineStyle(
            color: kPrimaryColor.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(6),
            width: 1.5,
            spacing: 0,
          ),
      style:
          (style) => style.copyWith(
            cursor: const FWidgetStateMap({
              WidgetState.any: SystemMouseCursors.click,
            }),
          ),
      builder:
          (context, states, _) => SingleMotionBuilder(
            value:
                !selected && states.contains(WidgetState.hovered) ? 1.0 : 0.0,
            motion: DesktopMotion.hover,
            builder: (context, value, _) {
              final t = value.clamp(0.0, 1.0);
              return SizedBox(
                width: padding.horizontal + width,
                height: _height,
                child: CustomPaint(
                  painter:
                      selected
                          ? _TabRulePainter(left: padding.left, width: width)
                          : null,
                  child: Padding(
                    padding: padding,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: _style.copyWith(
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                          color:
                              selected
                                  ? kWhiteColor
                                  : Color.lerp(kWhiteColor70, kWhiteColor, t),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }
}

/// The chosen tab's rule: as wide as its label, 2 px tall with round caps,
/// under the label. Static: it never grows, slides or fades.
class _TabRulePainter extends CustomPainter {
  const _TabRulePainter({required this.left, required this.width});

  final double left;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final top = size.height - _TobyTab._ruleInset - _TobyTab._ruleHeight;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, width, _TobyTab._ruleHeight),
        const Radius.circular(_TobyTab._ruleHeight / 2),
      ),
      Paint()..color = kWhiteColor,
    );
  }

  @override
  bool shouldRepaint(_TabRulePainter old) =>
      old.left != left || old.width != width;
}
