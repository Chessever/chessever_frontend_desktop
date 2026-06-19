import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_feedback_dialog.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';

class DesktopWhatsNewHomePane extends StatelessWidget {
  const DesktopWhatsNewHomePane({
    super.key,
    required this.feedbackScreenshotKey,
  });

  final GlobalKey feedbackScreenshotKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBackgroundColor,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Welcome to ChessEver Desktop Beta',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              _FeedbackIntro(feedbackScreenshotKey: feedbackScreenshotKey),
              const SizedBox(height: 28),
              const Text(
                'Quick start / power tips',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              const _PowerTipsList(),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeedbackIntro extends StatelessWidget {
  const _FeedbackIntro({required this.feedbackScreenshotKey});

  final GlobalKey feedbackScreenshotKey;

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      color: kWhiteColor70,
      fontSize: 14,
      height: 1.55,
    );
    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          const TextSpan(
            text:
                'ChessEver Desktop is still in beta, and we are improving it quickly. If something feels confusing, slow, missing, or not useful enough, please send us ',
          ),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: CursorAware(
              mode: CursorMode.hover,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap:
                    () => DesktopFeedbackDialog.show(
                      context,
                      screenshotKey: feedbackScreenshotKey,
                    ),
                child: const Text(
                  'feedback',
                  style: TextStyle(
                    color: kPrimaryColor,
                    fontSize: 14,
                    height: 1.55,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.underline,
                    decorationColor: kPrimaryColor,
                  ),
                ),
              ),
            ),
          ),
          const TextSpan(text: '.'),
        ],
      ),
    );
  }
}

class _PowerTipsList extends StatelessWidget {
  const _PowerTipsList();

  static const _tips = [
    _PowerTipData(
      shortcut: 'Drag tab',
      text:
          'Drag a game tab out to use it in a separate window — especially useful with two screens.',
    ),
    _PowerTipData(
      shortcut: 'Ctrl/Cmd + click',
      text: 'Open a game or tab separately, where supported.',
    ),
    _PowerTipData(
      shortcut: 'Ctrl/Cmd + F',
      text: 'Search — useful when preparing for opponents.',
    ),
    _PowerTipData(shortcut: 'Enter', text: 'Open Explorer from the board.'),
    _PowerTipData(
      shortcut: '↑ / ↓',
      text: 'After clicking a game in Explorer, move between games.',
    ),
    _PowerTipData(shortcut: '← / →', text: 'Move through the current game.'),
    _PowerTipData(
      shortcut: 'Enter',
      text: 'Insert/open the selected Explorer game.',
    ),
    _PowerTipData(
      shortcut: 'Shift + ↑ / ↓',
      text: 'Move between Notation, Tree, and Games.',
    ),
    _PowerTipData(
      shortcut: 'Ctrl/Cmd + ↑ / ↓',
      text: 'Go to the previous/next game.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < _tips.length; i++) ...[
          _PowerTip(tip: _tips[i]),
          if (i != _tips.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _PowerTip extends StatelessWidget {
  const _PowerTip({required this.tip});

  final _PowerTipData tip;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ShortcutPill(shortcut: tip.shortcut),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tip.text,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutPill extends StatelessWidget {
  const _ShortcutPill({required this.shortcut});

  final String shortcut;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 104),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        shortcut,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _PowerTipData {
  const _PowerTipData({required this.shortcut, required this.text});

  final String shortcut;
  final String text;
}
