import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:chessever/theme/app_theme.dart';

/// The setup page every Play mode starts from: a title, two columns of
/// [PlaySetupCard]s (stacked on narrow windows) and a [PlaySetupStartBar]
/// underneath. Single games and tournaments share it, so both are set up
/// the same way.
class PlaySetupPage extends StatelessWidget {
  const PlaySetupPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.left,
    required this.right,
    required this.startBar,
  });

  final String title;
  final String subtitle;
  final List<Widget> left;
  final List<Widget> right;
  final Widget startBar;

  static const double _cardGap = 18;

  @override
  Widget build(BuildContext context) {
    Widget column(List<Widget> cards) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: _cardGap),
          cards[i],
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 980;
        final body =
            stacked
                ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    column(left),
                    const SizedBox(height: 24),
                    column(right),
                  ],
                )
                : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: column(left)),
                    const SizedBox(width: 28),
                    Expanded(child: column(right)),
                  ],
                );
        return DesktopScrollHost(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(40, 36, 40, 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PlaySetupHeader(title: title, subtitle: subtitle),
                  const SizedBox(height: 28),
                  body,
                  const SizedBox(height: 32),
                  startBar,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class PlaySetupHeader extends StatelessWidget {
  const PlaySetupHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 14,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// One titled group of setup controls.
class PlaySetupCard extends StatelessWidget {
  const PlaySetupCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;

  /// Sits at the end of the title row, such as a selection count.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// The bar under the setup cards: what will start, and the buttons that
/// start it.
class PlaySetupStartBar extends StatelessWidget {
  const PlaySetupStartBar({
    super.key,
    required this.summary,
    required this.detail,
    required this.actions,
    this.detailIsError = false,
  });

  final String summary;
  final String detail;
  final List<Widget> actions;

  /// Shows [detail] as a problem to fix, such as a failed start.
  final bool detailIsError;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: TextStyle(
                      color: detailIsError ? kRedColor : kSecondaryTextColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            for (final action in actions) ...[
              const SizedBox(width: 12),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
