/// The Toby bar: Toby's chances of a White win, a draw and a Black win for
/// the position the board shows, as a vertical bar on the board's right
/// (the eval bar keeps the left). Free for every reader, guests included,
/// and on by default (`EngineSettings.showTobyBar`).
///
/// It reads `positionWdl` from the same [tobyReadingProvider] instance as
/// the Toby Predicts view ([tobyQueryFor]), so a board asks about a
/// position once for both. The network stage shows at once, the final
/// stage refines it, and while the next position is read the bar keeps the
/// last values it drew. A position whose game is over shows the result and
/// asks nothing.
///
/// Two copies, one rule: chessever_web_frontend `src/broadcast/lib/toby-bar.ts`
/// draws the same bar on chessever.com (geometry, the 18 px label
/// threshold, the game-over order and accepted result strings, and the
/// empty track). Change one, change both, each with its tests.
library;

import 'package:dartchess/dartchess.dart' show Outcome, Side;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart' show FTooltipController;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/utils/text_line_metrics.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/toby/what_toby_thinks.dart'
    show TobyTarget;
import 'package:chessever/theme/app_theme.dart';

/// White's segment: the eval bar's light tone.
const Color kTobyBarWhite = kWhiteColor;

/// Black's segment: the eval bar's dark tone.
const Color kTobyBarBlack = kPopUpColor;

/// The draw: a neutral mid grey between the two.
const Color kTobyBarDraw = Color(0xFF8A8A8A);

/// The track with nothing to show (no reading yet, an error, a refusal): a
/// flat surface a step off the pane, with no numbers.
const Color kTobyBarEmpty = kBlack3Color;

/// How long a boundary takes to move to a new reading.
const Duration kTobyBarTransition = Duration(milliseconds: 300);

/// Clear space a label keeps above and below itself inside its segment.
const double kTobyBarLabelPadding = 3;

/// The least segment height that carries a figure: the web's
/// `TOBY_BAR_LABEL_MIN_PX`. A larger text scale raises it to the line plus
/// [kTobyBarLabelPadding] above and below, so a figure is never cut.
const double kTobyBarLabelMinExtent = 18;

/// The figures inside the bar: the eval bar's face and size, with tabular
/// numerals so the digits do not jitter as a reading refines.
const TextStyle kTobyBarLabelStyle = TextStyle(
  inherit: false,
  fontFamily: 'Geist',
  fontSize: 11,
  fontWeight: FontWeight.w700,
  height: 1.0,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Which outcome a segment of the bar stands for.
enum TobyBarSide { white, draw, black }

/// One segment of the bar, top to bottom: where it starts and how tall it is
/// in logical pixels, its whole percentage, and whether its figure fits
/// inside it whole.
typedef TobyBarSlice =
    ({TobyBarSide side, double top, double extent, int percent, bool label});

/// The bar's segments for [wdl], top to bottom, [height] tall: White at
/// White's end (the bottom, or the top when [flipped]), Black at the other,
/// the draw between. A figure shows only where its segment is at least
/// [kTobyBarLabelMinExtent] tall and holds the [labelExtent]-tall text with
/// [kTobyBarLabelPadding] above and below it, and never for 0%.
/// No [wdl] is the empty track: no segments.
List<TobyBarSlice> tobyBarSlices({
  required TobyWdl? wdl,
  required bool flipped,
  required double height,
  required double labelExtent,
}) {
  if (wdl == null || !(height > 0)) return const <TobyBarSlice>[];
  final percentages = wdl.percentages;
  final order =
      flipped
          ? const [TobyBarSide.white, TobyBarSide.draw, TobyBarSide.black]
          : const [TobyBarSide.black, TobyBarSide.draw, TobyBarSide.white];
  double share(TobyBarSide side) => switch (side) {
    TobyBarSide.white => wdl.white,
    TobyBarSide.draw => wdl.draw,
    TobyBarSide.black => wdl.black,
  };
  int percent(TobyBarSide side) => switch (side) {
    TobyBarSide.white => percentages.white,
    TobyBarSide.draw => percentages.draw,
    TobyBarSide.black => percentages.black,
  };
  final need = labelExtent + 2 * kTobyBarLabelPadding;
  final least = need > kTobyBarLabelMinExtent ? need : kTobyBarLabelMinExtent;
  final slices = <TobyBarSlice>[];
  var top = 0.0;
  for (final side in order) {
    final extent = (share(side).clamp(0.0, 1.0) * height).toDouble();
    slices.add((
      side: side,
      top: top,
      extent: extent,
      percent: percent(side),
      label: percent(side) > 0 && extent >= least,
    ));
    top += extent;
  }
  return slices;
}

const TobyWdl _whiteWon = TobyWdl(white: 1, draw: 0, black: 0);
const TobyWdl _blackWon = TobyWdl(white: 0, draw: 0, black: 1);
const TobyWdl _drawn = TobyWdl(white: 0, draw: 1, black: 0);

/// The bar for a game that is over on the board: all White for 1-0, all
/// Black for 0-1, all draw for a draw. [pgnResult] (the game's result,
/// passed only at its last published position: a resignation, a flag, an
/// agreed draw) is read first, then the board's own [outcome] (checkmate,
/// stalemate, a dead position) anywhere. Null while the game goes on.
///
/// Accepted results, the same set as the web's `tobyBarResult`, whitespace
/// ignored: `1-0`, `1.0-0.0`, `1-0.0`; `0-1`, `0.0-1.0`, `0.0-1`;
/// `1/2-1/2`, `½-½`, `1/2`, `0.5-0.5`.
TobyWdl? tobyResultWdl({Outcome? outcome, String? pgnResult}) {
  final result = pgnResult?.replaceAll(RegExp(r'\s+'), '');
  final fromPgn = switch (result) {
    '1-0' || '1.0-0.0' || '1-0.0' => _whiteWon,
    '0-1' || '0.0-1.0' || '0.0-1' => _blackWon,
    '1/2-1/2' || '½-½' || '1/2' || '0.5-0.5' => _drawn,
    _ => null,
  };
  if (fromPgn != null) return fromPgn;
  if (outcome == null) return null;
  return switch (outcome.winner) {
    Side.white => _whiteWon,
    Side.black => _blackWon,
    null => _drawn,
  };
}

/// What the bar draws for [state], given the [previous] values it drew.
///
/// A reading (the network stage, the final one, or a stage kept through a
/// busy budget) shows its `positionWdl`. While the position is still being
/// read the previous values stay up, so stepping through a game never
/// flashes the bar empty. An error, a refusal or a reading without chances
/// is the empty track.
TobyWdl? tobyBarWdlFor(TobyReadingState state, TobyWdl? previous) {
  switch (state.status) {
    case TobyStatus.thinking:
      return previous;
    case TobyStatus.network:
    case TobyStatus.ready:
    case TobyStatus.busy:
      return state.reading?.positionWdl;
    case TobyStatus.unavailable:
    case TobyStatus.premiumUnconfirmed:
    case TobyStatus.premiumRequired:
    case TobyStatus.signInRequired:
    case TobyStatus.notApplicable:
      return null;
  }
}

/// The bar's accessible name: "Toby: White 12%, draw 76%, Black 11%".
String tobyBarSemanticsLabel(TobyWdl? wdl, {bool result = false}) {
  if (wdl == null) return 'Toby: no reading';
  final p = wdl.percentages;
  final chances = 'White ${p.white}%, draw ${p.draw}%, Black ${p.black}%';
  return result ? 'Toby: game over, $chances' : 'Toby: $chances';
}

/// The bar's tooltip: what it is, the inputs Toby read with (the same line
/// as the Toby Predicts view's), and Toby's attribution.
String tobyBarTooltip({String? inputs, bool result = false}) => [
  result
      ? 'The game is over: the bar shows its result.'
      : 'Toby: the chances of a White win, a draw and a Black win for '
          'these players at this time control.',
  if (!result && inputs != null) inputs,
  kTobyAttribution,
].join('\n');

/// The Toby bar for one board. Its board pane hands it the board's Toby
/// [target] (what the Toby Predicts view reads too), the [controller] that
/// owns the board's session and what-if, and the [result] when the game is
/// over on the board. A leaf: a reading rebuilds this bar and nothing
/// around it.
///
/// [positionKey] is the FEN of the board's own position (not a previewed
/// line). Kept values are drawn only while they belong to it: a background
/// board in a split whose game moves on shows the empty track, never the
/// chances of a position it no longer shows.
class TobyBarSurface extends ConsumerStatefulWidget {
  const TobyBarSurface({
    super.key,
    required this.target,
    required this.controller,
    required this.result,
    required this.positionKey,
    required this.flipped,
    required this.width,
    required this.height,
  });

  final TobyTarget target;
  final String positionKey;
  final TobyPanelController controller;
  final TobyWdl? result;
  final bool flipped;
  final double width;
  final double height;

  @override
  ConsumerState<TobyBarSurface> createState() => _TobyBarSurfaceState();
}

class _TobyBarSurfaceState extends ConsumerState<TobyBarSurface> {
  /// The chances last drawn, kept while the next position is read, a line
  /// is previewed, or the board steps into the background.
  TobyWdl? _shown;

  /// The position [_shown] was read for.
  String? _shownKey;
  String? _inputs;

  @override
  void initState() {
    super.initState();
    widget.controller.whatIfListenable.addListener(_onWhatIf);
  }

  @override
  void didUpdateWidget(covariant TobyBarSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.whatIfListenable.removeListener(_onWhatIf);
      widget.controller.whatIfListenable.addListener(_onWhatIf);
    }
  }

  @override
  void dispose() {
    widget.controller.whatIfListenable.removeListener(_onWhatIf);
    super.dispose();
  }

  void _onWhatIf() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    if (result != null) {
      return TobyBar(
        wdl: result,
        flipped: widget.flipped,
        width: widget.width,
        height: widget.height,
        result: true,
      );
    }
    final request = widget.target.request;
    if (request != null) {
      final query = tobyQueryFor(request, widget.controller);
      // The state changes only when the status or the reading does, so
      // this rebuilds the bar a few times per position at most.
      final state = ref.watch(tobyReadingProvider(query));
      if (state.status != TobyStatus.thinking) {
        // A settled state belongs to this position; while it is being
        // read the previous values (and their position) stay up.
        _shown = tobyBarWdlFor(state, _shown);
        _shownKey = widget.target.positionKey;
      }
      _inputs =
          (state.reading?.inputs ?? TobyInputs.expectedFor(query.request))
              .label;
    } else if (_shownKey != widget.positionKey) {
      // Idle (a previewed line, a background board): the last values stay
      // only while the board still stands on the position they describe.
      _shown = null;
      _shownKey = null;
    }
    return TobyBar(
      wdl: _shown,
      flipped: widget.flipped,
      width: widget.width,
      height: widget.height,
      inputs: _inputs,
    );
  }
}

/// The bar itself, drawn from [wdl] (null for the empty track).
class TobyBar extends StatefulWidget {
  const TobyBar({
    super.key,
    required this.wdl,
    required this.flipped,
    required this.width,
    required this.height,
    this.inputs,
    this.result = false,
  });

  final TobyWdl? wdl;
  final bool flipped;
  final double width;
  final double height;

  /// The inputs line for the tooltip ("2650 v 2610 · Classical").
  final String? inputs;

  /// Whether [wdl] is the game's result rather than Toby's reading.
  final bool result;

  @override
  State<TobyBar> createState() => _TobyBarState();
}

class _TobyBarState extends State<TobyBar> with TickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: kTobyBarTransition,
    value: 1,
  );
  late final Animation<double> _eased = CurvedAnimation(
    parent: _motion,
    curve: Curves.easeOutCubic,
  );
  TobyWdl? _from;

  /// The tip opens on hover and on keyboard focus alike.
  late final FTooltipController _tip = FTooltipController(vsync: this);
  bool _focused = false;

  void _onFocus(bool focused) {
    setState(() => _focused = focused);
    if (focused) {
      _tip.show();
    } else {
      _tip.hide();
    }
  }

  @override
  void didUpdateWidget(covariant TobyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.wdl;
    final previous = oldWidget.wdl;
    if (next == previous) return;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // From or to the empty track there is no boundary to move: the
    // segments simply appear (they are never hidden behind a fade).
    if (next == null || previous == null || reduceMotion) {
      _from = null;
      _motion.value = 1;
      return;
    }
    _from = _lerp(_from ?? previous, previous, _eased.value);
    _motion.forward(from: 0);
  }

  @override
  void dispose() {
    _tip.dispose();
    _motion.dispose();
    super.dispose();
  }

  static TobyWdl _lerp(TobyWdl a, TobyWdl b, double t) => TobyWdl(
    white: a.white + (b.white - a.white) * t,
    draw: a.draw + (b.draw - a.draw) * t,
    black: a.black + (b.black - a.black) * t,
  );

  /// [percent] centred in [slice], or nothing when it does not fit whole.
  Widget? _figure(BuildContext context, TobyBarSlice slice, int percent) {
    if (!slice.label) return null;
    final text = '$percent';
    final style = kTobyBarLabelStyle.copyWith(color: _ink(slice.side));
    if (desktopTextLineSize(context, text, style).width > widget.width) {
      return null;
    }
    return Center(
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        textAlign: TextAlign.center,
        style: style,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wdl = widget.wdl;
    final lineHeight =
        desktopTextLineSize(context, '0', kTobyBarLabelStyle).height;
    final bar = SizedBox(
      width: widget.width,
      height: widget.height,
      child: ColoredBox(
        color: wdl == null ? kTobyBarEmpty : kTobyBarDraw,
        child:
            wdl == null
                ? null
                : AnimatedBuilder(
                  animation: _eased,
                  builder: (context, _) {
                    final from = _from;
                    final drawn =
                        from == null || _motion.isCompleted
                            ? wdl
                            : _lerp(from, wdl, _eased.value);
                    // The geometry is the animated one, the figures the
                    // reading's: a figure shows once its segment holds it
                    // whole, down and across.
                    final slices = tobyBarSlices(
                      wdl: drawn,
                      flipped: widget.flipped,
                      height: widget.height,
                      labelExtent: lineHeight,
                    );
                    final p = wdl.percentages;
                    return Stack(
                      children: [
                        for (final slice in slices)
                          Positioned(
                            key: ValueKey<TobyBarSide>(slice.side),
                            left: 0,
                            right: 0,
                            top: slice.top,
                            height: slice.extent,
                            child: ColoredBox(
                              color: _fill(slice.side),
                              child: _figure(context, slice, switch (slice
                                  .side) {
                                TobyBarSide.white => p.white,
                                TobyBarSide.draw => p.draw,
                                TobyBarSide.black => p.black,
                              }),
                            ),
                          ),
                      ],
                    );
                  },
                ),
      ),
    );
    return Focus(
      onFocusChange: _onFocus,
      child: Semantics(
        container: true,
        label: tobyBarSemanticsLabel(wdl, result: widget.result),
        child: DesktopTooltip(
          controller: _tip,
          message: tobyBarTooltip(inputs: widget.inputs, result: widget.result),
          tipAnchor: Alignment.centerLeft,
          childAnchor: Alignment.centerRight,
          child: ExcludeSemantics(
            child: Container(
              // Keyboard focus: a solid ring in the figures' soft white,
              // drawn over the bar so its layout never moves.
              foregroundDecoration:
                  _focused
                      ? BoxDecoration(
                        border: Border.all(color: kWhiteColor70, width: 2),
                      )
                      : null,
              child: RepaintBoundary(child: bar),
            ),
          ),
        ),
      ),
    );
  }
}

Color _fill(TobyBarSide side) => switch (side) {
  TobyBarSide.white => kTobyBarWhite,
  TobyBarSide.draw => kTobyBarDraw,
  TobyBarSide.black => kTobyBarBlack,
};

/// Each figure's ink, well clear of its segment: dark on White's and the
/// draw's, a soft white on Black's.
Color _ink(TobyBarSide side) => switch (side) {
  TobyBarSide.white => kTobyBarBlack,
  TobyBarSide.draw => kTobyBarBlack,
  TobyBarSide.black => kWhiteColor70,
};

@visibleForTesting
Color tobyBarInkFor(TobyBarSide side) => _ink(side);
