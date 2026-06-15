import 'package:flutter/material.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';

/// Compact move-navigation cluster shown directly under the chessboard.
///
/// The buttons intentionally share one quiet visual treatment: game jumps,
/// move jumps, autoplay, and flip-board should read as one native Chess Ever
/// control strip rather than a copied media-player row with a special primary
/// play button.
///
/// Keyboard controls (← → / Home End / F) are wired at the pane root via
/// `Shortcuts`/`Actions`, not on this widget — the bar is purely visual.
class MoveNavigationBar extends StatelessWidget {
  const MoveNavigationBar({
    super.key,
    required this.canGoBack,
    required this.canGoForward,
    required this.onFirst,
    required this.onPrevious,
    required this.onNext,
    required this.onLast,
    this.onFlipBoard,
    this.showFlipBoard = true,
    this.onPlayPause,
    this.onPreviousGame,
    this.onNextGame,
    this.isPlaying = false,
    this.moveLabel,
    this.hasUnseenLiveMove = false,
  });

  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onFirst;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onLast;
  final VoidCallback? onFlipBoard;
  final bool showFlipBoard;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPreviousGame;
  final VoidCallback? onNextGame;
  final bool isPlaying;

  /// Optional label shown above the cluster — typically "23. Nf3" or
  /// "12 / 47" so the user can see where they are in the game.
  final String? moveLabel;

  /// When true, draws a small blinking red dot on the top-right corner
  /// of the "Last move" button — used during live broadcasts to signal
  /// a fresh tick landed while the user is exploring an earlier ply.
  /// Rendered as an overlay so showing/hiding the dot does not change
  /// the bar's bounds and the board height stays fixed.
  final bool hasUnseenLiveMove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(color: kBackgroundColor),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (moveLabel != null && moveLabel!.isNotEmpty) ...[
            Text(
              moveLabel!,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (onPreviousGame != null) ...[
                _NavButton(
                  icon: Icons.keyboard_double_arrow_left_rounded,
                  tooltip: 'Previous game',
                  enabled: true,
                  onTap: onPreviousGame!,
                  size: _kButtonSize,
                ),
                const SizedBox(width: 8),
              ],
              _NavButton(
                icon: Icons.first_page_rounded,
                tooltip: 'First move (Home)',
                enabled: canGoBack,
                onTap: onFirst,
                size: _kButtonSize,
              ),
              const SizedBox(width: 8),
              _NavButton(
                icon: Icons.chevron_left_rounded,
                tooltip: 'Previous move (←)',
                enabled: canGoBack,
                onTap: onPrevious,
                size: _kButtonSize,
              ),
              if (onPlayPause != null) ...[
                const SizedBox(width: 8),
                _NavButton(
                  icon: isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  tooltip: isPlaying
                      ? 'Pause autoplay (Space)'
                      : 'Autoplay (Space)',
                  enabled: canGoForward || isPlaying,
                  onTap: onPlayPause!,
                  size: _kButtonSize,
                ),
                const SizedBox(width: 8),
              ] else
                const SizedBox(width: 8),
              _NavButton(
                icon: Icons.chevron_right_rounded,
                tooltip: 'Next move (→)',
                enabled: canGoForward,
                onTap: onNext,
                size: _kButtonSize,
              ),
              const SizedBox(width: 8),
              _LastMoveButton(
                enabled: canGoForward,
                onTap: onLast,
                showLiveDot: hasUnseenLiveMove,
              ),
              if (onNextGame != null) ...[
                const SizedBox(width: 8),
                _NavButton(
                  icon: Icons.keyboard_double_arrow_right_rounded,
                  tooltip: 'Next game',
                  enabled: true,
                  onTap: onNextGame!,
                  size: _kButtonSize,
                ),
              ],
              if (showFlipBoard && onFlipBoard != null) ...[
                const SizedBox(width: 16),
                // Flip board sits separated from the move-step cluster by a
                // wider gap so it doesn't read as another sibling step.
                _NavButton(
                  icon: Icons.flip_camera_android_rounded,
                  tooltip: 'Flip board (F)',
                  enabled: true,
                  onTap: onFlipBoard!,
                  size: _kButtonSize,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

const double _kButtonSize = 40;

/// Last-move nav button with an optional blinking red dot overlay used to
/// announce a new broadcast tick. The dot is positioned absolutely on the
/// button's top-right corner so toggling [showLiveDot] never changes the
/// surrounding layout.
class _LastMoveButton extends StatefulWidget {
  const _LastMoveButton({
    required this.enabled,
    required this.onTap,
    required this.showLiveDot,
  });

  final bool enabled;
  final VoidCallback onTap;
  final bool showLiveDot;

  @override
  State<_LastMoveButton> createState() => _LastMoveButtonState();
}

class _LastMoveButtonState extends State<_LastMoveButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    if (widget.showLiveDot) _blink.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _LastMoveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showLiveDot == widget.showLiveDot) return;
    if (widget.showLiveDot) {
      _blink.repeat(reverse: true);
    } else {
      _blink
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kButtonSize,
      height: _kButtonSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _NavButton(
              icon: Icons.last_page_rounded,
              tooltip: widget.showLiveDot
                  ? 'New move — jump to live (End)'
                  : 'Last move (End)',
              enabled: widget.enabled,
              onTap: widget.onTap,
              size: _kButtonSize,
            ),
          ),
          if (widget.showLiveDot)
            Positioned(
              top: -2,
              right: -2,
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: Tween<double>(begin: 0.35, end: 1.0).animate(
                    CurvedAnimation(parent: _blink, curve: Curves.easeInOut),
                  ),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5484D),
                      shape: BoxShape.circle,
                      border: Border.all(color: kBackgroundColor, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFE5484D).withValues(alpha: 0.6),
                          blurRadius: 6,
                        ),
                      ],
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

class _NavButton extends StatefulWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    required this.size,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  final double size;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = !widget.enabled;
    final iconSize = widget.size * 0.50;

    final Color bg;
    final Color iconColor;
    final Color border;

    // One quiet button language for every control, including Play/Pause.
    iconColor = disabled
        ? kLightGreyColor
        : (_hovered ? kWhiteColor : kWhiteColor70);
    bg = disabled
        ? Colors.transparent
        : (_pressed
              ? kBlack3Color
              : (_hovered ? kBlack2Color : Colors.transparent));
    border = disabled
        ? Colors.transparent
        : (_hovered ? kPrimaryColor.withValues(alpha: 0.4) : kDividerColor);

    return DesktopTooltip(
      message: widget.tooltip,
      child: ClickCursor(
        enabled: !disabled,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
            onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
            onTapCancel: disabled
                ? null
                : () => setState(() => _pressed = false),
            onTap: disabled ? null : widget.onTap,
            child: SingleMotionBuilder(
              value: disabled
                  ? 1.0
                  : (_pressed ? 0.93 : (_hovered ? 1.04 : 1.0)),
              motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
              builder: (context, scale, child) => Transform.scale(
                scale: scale,
                alignment: Alignment.center,
                child: child,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: border),
                ),
                alignment: Alignment.center,
                child: Icon(widget.icon, size: iconSize, color: iconColor),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
