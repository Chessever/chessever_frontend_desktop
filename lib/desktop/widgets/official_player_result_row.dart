import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chessever/services/official_round_results.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'cursor_mode.dart';
import 'desktop_tooltip.dart';

/// A verified outcome, not a playable game. Opponent activation is independent.
class OfficialPlayerResultRow extends StatefulWidget {
  const OfficialPlayerResultRow({
    super.key,
    required this.result,
    this.roundLabel,
    this.ratingChange,
    this.onOpenOpponent,
    this.compact = false,
  });
  final OfficialRoundResult result;
  final String? roundLabel;
  final int? ratingChange;
  final VoidCallback? onOpenOpponent;
  final bool compact;

  @override
  State<OfficialPlayerResultRow> createState() =>
      _OfficialPlayerResultRowState();
}

class _OfficialPlayerResultRowState extends State<OfficialPlayerResultRow> {
  static const _hint = 'Only the result is available.';
  final _focus = FocusNode();
  bool _expanded = false;
  @override
  void didUpdateWidget(covariant OfficialPlayerResultRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) _expanded = false;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _activate() {
    if (!_focus.hasFocus) _focus.requestFocus();
    setState(() => _expanded = true);
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final roundLabel = widget.roundLabel;
    final ratingChange = widget.ratingChange;
    final compact = widget.compact;
    final onOpenOpponent = widget.onOpenOpponent;
    final white = result.color == 'white';
    final rating = result.opponentRating;
    final glyph = result.points == .5 ? '½' : result.points.toInt().toString();
    final name = Text(
      result.opponentName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
    return GestureDetector(
      onTap: _activate,
      behavior: HitTestBehavior.opaque,
      child: TapRegion(
        onTapOutside: (_) {
          if (_expanded) setState(() => _expanded = false);
        },
        child: Focus(
          focusNode: _focus,
          skipTraversal: true,
          onFocusChange: (focused) {
            if (!focused && _expanded) setState(() => _expanded = false);
          },
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.space)) {
              _activate();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: DesktopTooltip(
            message: _hint,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 12 : 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          roundLabel ?? 'R${result.roundNumber}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _activate,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: result.nonPlayed ? 46 : 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: white ? kWhiteColor : kBlackColor,
                            border: Border.all(
                              color: kWhiteColor.withValues(alpha: .28),
                            ),
                          ),
                          child: Text(
                            '$glyph${result.nonPlayed ? ' NP' : ''}',
                            style: TextStyle(
                              color: white ? kBlackColor : kWhiteColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (result.opponentFed?.trim().isNotEmpty ?? false) ...[
                        BackfilledFederationFlag(
                          federation: result.opponentFed!,
                          fideId: int.tryParse(result.opponentFideId ?? ''),
                          playerName: result.opponentName,
                          width: 20,
                          height: 14,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        const SizedBox(width: 7),
                      ],
                      if (result.opponentTitle?.trim().isNotEmpty ?? false) ...[
                        Text(
                          result.opponentTitle!,
                          style: const TextStyle(
                            color: kPrimaryColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child:
                            onOpenOpponent == null || result.color == null
                                ? name
                                : ClickCursor(
                                  child: GestureDetector(
                                    onTap: onOpenOpponent,
                                    behavior: HitTestBehavior.opaque,
                                    child: name,
                                  ),
                                ),
                      ),
                      if (rating != null && rating.isFinite && rating > 0) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${rating.round()}',
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      if (ratingChange != null) ...[
                        const SizedBox(width: 6),
                        DesktopTooltip(
                          message: 'Estimated rating change',
                          child: Text(
                            '${ratingChange > 0 ? '+' : ''}$ratingChange',
                            style: TextStyle(
                              color:
                                  ratingChange > 0
                                      ? kGreenColor
                                      : ratingChange < 0
                                      ? kRedColor
                                      : kWhiteColor70,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_expanded)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 0, 14, 8),
                    child: Text(
                      _hint,
                      style: TextStyle(color: kLightGreyColor, fontSize: 11),
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
