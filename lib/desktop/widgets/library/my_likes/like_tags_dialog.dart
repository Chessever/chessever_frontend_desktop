import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/chessboard/models/like_tag.dart';
import 'package:chessever/theme/app_theme.dart';

/// Opens the tag editor for the like identified by [likeId] (its
/// `sourceGameId`). Every tap persists immediately; rapid taps are serialized
/// by the liked-games notifier so the last selection is the final value.
/// Tagging is never gated.
Future<void> showLikeTagsDialog(BuildContext context, String likeId) {
  return showDesktopDialog<void>(
    context,
    builder: (_) => _LikeTagsDialog(likeId: likeId),
  );
}

class _LikeTagsDialog extends ConsumerWidget {
  const _LikeTagsDialog({required this.likeId});

  final String likeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(likedGameTagsProvider(likeId));
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kDividerColor),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Tags',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 6,
                  runSpacing: 0,
                  children: [
                    for (final tag in kLikeTags)
                      LikeTagToggle(
                        tag: tag,
                        selected: selected.contains(tag.label),
                        onPressed: () {
                          final next = <String>[...selected];
                          if (!next.remove(tag.label)) next.add(tag.label);
                          ref
                              .read(likedGamesProvider.notifier)
                              .setTagsForLikeId(likeId, next);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: DesktopDialogButton(
                    label: 'Done',
                    tone: DesktopDialogButtonTone.secondary,
                    onPress: () => Navigator.of(context).pop(),
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

/// A tag as a quiet toggle: the tag's colour is a small dot, not a fill, and
/// the selected state borrows the sidebar's tinted-accent treatment.
class LikeTagToggle extends StatefulWidget {
  const LikeTagToggle({
    super.key,
    required this.tag,
    required this.selected,
    required this.onPressed,
    this.count,
  });

  final LikeTag tag;
  final bool selected;
  final VoidCallback onPressed;
  final int? count;

  @override
  State<LikeTagToggle> createState() => _LikeTagToggleState();
}

class _LikeTagToggleState extends State<LikeTagToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final border =
        selected ? kPrimaryColor.withValues(alpha: 0.35) : kDividerColor;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.tag.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          // 32px chip inside a 40px hit area.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            // Fill and label colour ease on the shared hover spring instead
            // of snapping, matching the sidebar's chip vocabulary.
            child: SingleMotionBuilder(
              value: _hovered ? 1.0 : 0.0,
              motion: DesktopMotion.hover,
              builder: (context, h, _) {
                final t = h.clamp(0.0, 1.0);
                final background =
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.10 + 0.06 * t)
                        : Color.lerp(Colors.transparent, kBlack3Color, t)!;
                final foreground =
                    selected
                        ? kPrimaryColor
                        : Color.lerp(kWhiteColor70, kWhiteColor, t)!;
                return Container(
                  constraints: const BoxConstraints(minHeight: 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: widget.tag.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        widget.tag.label,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.count != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${widget.count}',
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 11.5,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
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
