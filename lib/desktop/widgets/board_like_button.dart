import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/desktop_like_actions.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart'
    show compactLikeCount;
import 'package:chessever/desktop/state/game_like_count.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

/// Like for the game on the board, the phone's notation Like button on
/// desktop and the web port.
///
/// Sits first in the board's action row, beside Save: on the phone the like
/// heart flies into Save, so the two belong together. The heart is red in
/// both states, as every like heart in the app is; the fill says whether the
/// game is liked. The community count rides beside it once the server knows
/// it. A guest is asked to sign in first (see [toggleDesktopGameLike]).
class DesktopBoardLikeButton extends ConsumerStatefulWidget {
  const DesktopBoardLikeButton({super.key, required this.game});

  final GamesTourModel game;

  @override
  ConsumerState<DesktopBoardLikeButton> createState() =>
      _DesktopBoardLikeButtonState();
}

class _DesktopBoardLikeButtonState extends ConsumerState<DesktopBoardLikeButton>
    with DeferredPointerStateMixin<DesktopBoardLikeButton> {
  bool _hovered = false;
  bool _busy = false;

  /// Bumped whenever the liked state flips, here or anywhere else (a card's
  /// context menu, My Likes). Each bump replays the heart's spring.
  int _pops = 0;
  double _popFrom = 1;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await toggleDesktopGameLike(
        context: context,
        ref: ref,
        game: widget.game,
      );
      // The count is the server's; re-read it once the write has landed.
      if (result != null && mounted) {
        ref.invalidate(desktopGameLikeCountProvider(widget.game.likeId));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final likeId = widget.game.likeId;
    ref.listen<bool>(isGameLikedProvider(likeId), (previous, next) {
      if (previous == null || previous == next) return;
      setState(() {
        _pops++;
        // A like springs the heart in from small; an unlike only gives way.
        _popFrom = next ? 0.45 : 0.8;
      });
    });
    final liked = ref.watch(isGameLikedProvider(likeId));
    final likes = ref.watch(desktopGameLikeCountProvider(likeId)).valueOrNull;
    final showCount = likes != null && likes > 0;
    final countLabel = showCount ? compactLikeCount(likes) : null;

    final Color bg;
    final Color border;
    if (liked) {
      bg = kRedColor.withValues(alpha: _hovered ? 0.16 : 0.10);
      border = kRedColor.withValues(alpha: 0.40);
    } else {
      bg = _hovered ? kBlack3Color : Colors.transparent;
      border = _hovered ? kWhiteColor.withValues(alpha: 0.10) : kDividerColor;
    }

    final tooltip = [
      liked ? 'Liked. Click to remove from My Likes' : 'Like this game',
      if (showCount) likes == 1 ? '1 like' : '$likes likes',
    ].join('  •  ');

    return FTheme(
      data: FThemes.zinc.dark,
      child: Semantics(
        toggled: liked,
        value: showCount ? (likes == 1 ? '1 like' : '$likes likes') : null,
        child: ClickCursor(
          child: FTappable.static(
            semanticsLabel: liked ? 'Liked' : 'Like',
            excludeSemantics: true,
            behavior: HitTestBehavior.opaque,
            onHoverChange:
                (hovered) =>
                    setStateAfterPointerEvent(() => _hovered = hovered),
            onPress: _busy ? null : _toggle,
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            child: ExcludeFocus(
              child: DesktopTooltip(
                message: tooltip,
                child: AnimatedContainer(
                  key: const ValueKey('board-like-button'),
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  height: 36,
                  constraints: const BoxConstraints(minWidth: 36),
                  padding: EdgeInsets.symmetric(
                    horizontal: countLabel == null ? 0 : 10,
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SingleMotionBuilder(
                        key: ValueKey(_pops),
                        motion: DesktopMotion.select,
                        from: _pops == 0 ? 1 : _popFrom,
                        value: 1,
                        builder:
                            (context, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                        child: Icon(
                          liked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 19,
                          color: kRedColor,
                        ),
                      ),
                      if (countLabel != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          countLabel,
                          style: TextStyle(
                            color:
                                liked || _hovered ? kWhiteColor : kWhiteColor70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
