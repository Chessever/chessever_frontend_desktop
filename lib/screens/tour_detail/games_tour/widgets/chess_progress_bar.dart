import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const int _mateCpSentinel = 100_000;

@visibleForTesting
double normalizePvToProgressValue(Pv? pv) {
  if (pv == null) return 0.5;

  final sign = pv.whitePerspective ? 1 : -1;
  final eval =
      pv.cp.abs() == _mateCpSentinel
          ? ((pv.cp * sign) > 0 ? 10.0 : -10.0)
          : ((pv.cp * sign) / 100.0);

  return (eval.clamp(-5.0, 5.0) + 5.0) / 10.0;
}

@visibleForTesting
String formatPvForProgressLabel(Pv pv) {
  final sign = pv.whitePerspective ? 1 : -1;
  if (pv.isMate && pv.mate != null) {
    return '#${pv.mate! * sign}';
  }
  if (pv.cp.abs() == _mateCpSentinel) {
    return '#';
  }

  final value = (pv.cp * sign) / 100.0;
  final rounded = value.abs() < 0.05 ? 0.0 : value;
  if (rounded == 0.0) return '0.0';
  final formatted = rounded.toStringAsFixed(1);
  return rounded > 0 ? '+$formatted' : formatted;
}

class ChessProgressBar extends ConsumerStatefulWidget {
  const ChessProgressBar({
    required this.gamesTourModel,
    this.allowStockfishFallback = true,
    super.key,
  }) : isReversedMode = false;

  const ChessProgressBar.reversedMode({
    required this.gamesTourModel,
    this.allowStockfishFallback = true,
    super.key,
  }) : isReversedMode = true;

  final GamesTourModel gamesTourModel;
  final bool isReversedMode;
  final bool allowStockfishFallback;

  @override
  ConsumerState<ChessProgressBar> createState() => _ChessProgressBarState();
}

class _ChessProgressBarState extends ConsumerState<ChessProgressBar> {
  double oldEval = 0.5; // start at neutral midpoint
  String? oldLabel;

  @override
  Widget build(BuildContext context) {
    // Chess progress bar only needs 1 PV for evaluation
    final fen =
        resolveFreshestGameFen(
          fen: widget.gamesTourModel.fen,
          pgn: widget.gamesTourModel.pgn,
          lastMove: widget.gamesTourModel.lastMove,
        ) ??
        '';
    final evalAsync =
        widget.allowStockfishFallback
            ? ref.watch(gameCardEvalWithStockfishFallbackProvider(fen))
            : ref.watch(gameCardEvalCacheOnlyProvider(fen));

    final display = evalAsync.when(
      loading:
          () => _ProgressBarDisplay(
            value: oldEval,
            label: oldLabel,
            isLoading: oldLabel == null,
          ),
      error:
          (error, stack) =>
              _ProgressBarDisplay(value: oldEval, label: oldLabel),
      data: (cloud) {
        final pv = cloud.pvs.firstOrNull;
        if (pv == null) {
          return _ProgressBarDisplay(value: oldEval, label: oldLabel);
        }

        final normalized = normalizePvToProgressValue(pv);
        final label = formatPvForProgressLabel(pv);
        oldEval = normalized; // save for next frame
        oldLabel = label;
        return _ProgressBarDisplay(value: normalized, label: label);
      },
    );

    // Adjust for reversed mode (invert the evaluation visually)
    final displayEval =
        widget.isReversedMode ? (1.0 - display.value) : display.value;
    final labelText = display.label ?? (display.isLoading ? '...' : '');

    return SizedBox(
      width: 48.w,
      height: 12.h,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background
          Container(
            width: 48.w,
            height: 12.h,
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(4.br),
            ),
          ),

          // Foreground progress (white advantage)
          Align(
            alignment:
                widget.isReversedMode
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              width: (48.w * displayEval).clamp(0.0, 48.w),
              height: 12.h,
              decoration: BoxDecoration(
                color: kWhiteColor,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(
                    widget.isReversedMode && displayEval < 0.99 ? 0 : 4.br,
                  ),
                  bottomLeft: Radius.circular(
                    widget.isReversedMode && displayEval < 0.99 ? 0 : 4.br,
                  ),
                  topRight: Radius.circular(
                    !widget.isReversedMode && displayEval < 0.99 ? 0 : 4.br,
                  ),
                  bottomRight: Radius.circular(
                    !widget.isReversedMode && displayEval < 0.99 ? 0 : 4.br,
                  ),
                ),
              ),
            ),
          ),
          if (labelText.isNotEmpty)
            Center(
              child: Container(
                constraints: BoxConstraints(maxWidth: 44.w, maxHeight: 12.h),
                padding: EdgeInsets.symmetric(horizontal: 3.w),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kPrimaryColor,
                  borderRadius: BorderRadius.circular(3.br),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    labelText,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8.5.sp,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ProgressBarDisplay {
  const _ProgressBarDisplay({
    required this.value,
    this.label,
    this.isLoading = false,
  });

  final double value;
  final String? label;
  final bool isLoading;
}
