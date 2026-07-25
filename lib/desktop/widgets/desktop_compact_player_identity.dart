import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/table_display_value.dart';
import 'package:chessever/theme/app_theme.dart';

/// Parsed compact identity used by dense desktop game-card and event rows.
@immutable
class DesktopCompactPlayerNameParts {
  const DesktopCompactPlayerNameParts({
    required this.lastName,
    required this.firstInitial,
  });

  final String lastName;
  final String firstInitial;

  String get fullLabel =>
      firstInitial.isEmpty ? lastName : '$lastName, $firstInitial.';
}

/// Converts common chess-feed names to `Last, F.`.
///
/// Handles both canonical `Last, First` feeds and `First ... Last` fallbacks.
DesktopCompactPlayerNameParts desktopCompactPlayerNameParts(String rawName) {
  final name = desktopTablePlayerValue(rawName);
  if (name.isEmpty) {
    return const DesktopCompactPlayerNameParts(lastName: '', firstInitial: '');
  }

  String initialOf(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.characters.first.toUpperCase();
  }

  if (name.contains(',')) {
    final parts = name.split(',');
    final lastName = parts.first.trim();
    final firstName = parts.skip(1).join(',').trim();
    return DesktopCompactPlayerNameParts(
      lastName: lastName.isEmpty ? name : lastName,
      firstInitial: initialOf(firstName),
    );
  }

  final tokens =
      name.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
  if (tokens.length < 2) {
    return DesktopCompactPlayerNameParts(lastName: name, firstInitial: '');
  }
  final trailingToken = tokens.last.replaceAll('.', '');
  if (trailingToken.characters.length == 1) {
    return DesktopCompactPlayerNameParts(
      lastName: tokens.take(tokens.length - 1).join(' '),
      firstInitial: initialOf(trailingToken),
    );
  }
  return DesktopCompactPlayerNameParts(
    lastName: tokens.last,
    firstInitial: initialOf(tokens.first),
  );
}

String desktopCompactPlayerName(String rawName) {
  return desktopCompactPlayerNameParts(rawName).fullLabel;
}

/// One-line compact player name with a single-dot overflow contract.
///
/// The complete `Last, F.` form is shown whenever it fits. If it does not, the
/// first initial is dropped and the surname is clipped at the longest measured
/// prefix that fits followed by one period. This deliberately avoids Flutter's
/// three-dot ellipsis treatment.
class DesktopCompactPlayerNameText extends StatelessWidget {
  const DesktopCompactPlayerNameText({
    super.key,
    required this.name,
    required this.style,
    this.textAlign,
    this.fallback = 'Unknown',
  });

  final String name;
  final TextStyle style;
  final TextAlign? textAlign;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final parts = desktopCompactPlayerNameParts(name);
    final fullLabel = parts.fullLabel.isEmpty ? fallback : parts.fullLabel;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final display =
            maxWidth.isFinite &&
                    maxWidth > 0 &&
                    !_fits(context, fullLabel, maxWidth: maxWidth, style: style)
                ? _singleDotSurname(
                  context,
                  parts.lastName.isEmpty ? fallback : parts.lastName,
                  maxWidth: maxWidth,
                  style: style,
                )
                : fullLabel;
        return Text(
          display,
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          textAlign: textAlign,
          style: style,
        );
      },
    );
  }

  static String _singleDotSurname(
    BuildContext context,
    String surname, {
    required double maxWidth,
    required TextStyle style,
  }) {
    final characters = surname.characters.toList(growable: false);
    var best = '.';
    for (var length = 1; length <= characters.length; length++) {
      final candidate = '${characters.take(length).join()}.';
      if (!_fits(context, candidate, maxWidth: maxWidth, style: style)) {
        break;
      }
      best = candidate;
    }
    return best;
  }

  static bool _fits(
    BuildContext context,
    String text, {
    required double maxWidth,
    required TextStyle style,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    return !painter.didExceedMaxLines && painter.width <= maxWidth;
  }
}

/// Plain ChessEver-cyan chess title for compact desktop identities.
class DesktopPlainPlayerTitle extends StatelessWidget {
  const DesktopPlainPlayerTitle({
    super.key,
    required this.title,
    this.compact = false,
  });

  final String title;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Text(
      title.trim(),
      maxLines: 1,
      overflow: TextOverflow.fade,
      softWrap: false,
      style: TextStyle(
        color: kPrimaryColor,
        fontSize: compact ? 9.5 : 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
    );
  }
}
