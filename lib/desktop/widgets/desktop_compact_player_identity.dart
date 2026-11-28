import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/table_display_value.dart';
import 'package:chessever/theme/app_theme.dart';

/// One player name read by [desktopCompactPlayerNameParts].
///
/// Every compact player name on the desktop (and on app.chessever.com, which
/// runs the same code) is read by that one parser. Callers only format the
/// parts: `Surname,I` in the position games table, `Surname, I.` on cards
/// and in the Library, the surname alone on tabs and drag chips.
@immutable
class DesktopCompactPlayerNameParts {
  const DesktopCompactPlayerNameParts({
    required this.lastName,
    required this.firstInitial,
    this.name = '',
    this.isAsWritten = false,
  });

  /// The surname. For a name the rules cannot read ([isAsWritten]) it is the
  /// long-standing guess that the last word is the surname. Only labels that
  /// have room for one word read that guess: the surname-only labels
  /// ("Magnus Carlsen" -> "Carlsen") and the single-dot overflow of
  /// [DesktopCompactPlayerNameText].
  final String lastName;

  /// The upper-case first initial, or empty when there is none.
  final String firstInitial;

  /// The name after rule 1: title dropped, whitespace collapsed, and a
  /// trailing `(...)` dropped from a name without a comma.
  final String name;

  /// The name has no comma and no single surname to pick out ("Ding Liren",
  /// "Erigaisi Arjun", "Main line"). Its word order differs by source, so a
  /// full label shows [name] as written ([displayLabel]); reading the last
  /// word as the surname is what turned FIDE's "Gukesh D" into "D,G".
  final bool isAsWritten;

  /// `Surname, I.` from [lastName] and [firstInitial], guess included. No
  /// label shows it for an [isAsWritten] name; use [displayLabel].
  String get fullLabel =>
      firstInitial.isEmpty ? lastName : '$lastName, $firstInitial.';

  /// `Surname, I.`, or [name] as written when [isAsWritten]. Every full
  /// label (cards, Library and profile tables) shows this.
  String get displayLabel => isAsWritten ? name : fullLabel;
}

/// Reads a chess-feed player name into a surname and a first initial.
///
/// 1. Placeholders (`?`, `White`, `-`) read as empty unless
///    [keepPlaceholders]. A leading title (`GM`, `IM`, ...) is dropped, and
///    so is a trailing `(...)`, such as a federation, from a name without a
///    comma.
/// 2. With a comma, the surname is the text before the first comma and the
///    initial is the first letter after it: "Gukesh,D", "Carlsen, Magnus".
/// 3. Without a comma, exactly one word of two or more letters with single
///    initials around it is the surname, whatever the order: "Gukesh D",
///    "D Gukesh", "Narayanan S L" and "Gukesh D (IND)" all read Gukesh / D.
/// 4. Any other name without a comma is read as written
///    ([DesktopCompactPlayerNameParts.isAsWritten]): a full label shows it
///    whole and never moves its last word to the front.
DesktopCompactPlayerNameParts desktopCompactPlayerNameParts(
  String rawName, {
  bool keepPlaceholders = false,
}) {
  return _parseDesktopPlayerName(
    keepPlaceholders ? rawName : desktopTablePlayerValue(rawName),
  );
}

/// `Surname, I.`, or the name as written when the rules cannot read it
/// ("Ding Liren"), as game cards show it ([DesktopCompactPlayerNameText]).
String desktopCompactPlayerName(String rawName) {
  return desktopCompactPlayerNameParts(rawName).displayLabel;
}

/// The one word a surname-only label shows: tab titles, drag chips, short
/// names on cards, favorites and Library rows.
///
/// Rules 1-3 of [desktopCompactPlayerNameParts] pick the surname ("Gukesh D"
/// -> "Gukesh"). Any other name keeps the last word those labels have always
/// shown ("Magnus Carlsen" -> "Carlsen"), skipping a lone trailing initial.
/// Placeholders such as `White` come back as written, so each label keeps
/// its own handling of them.
String desktopPlayerSurname(String rawName) {
  final parts = desktopCompactPlayerNameParts(rawName, keepPlaceholders: true);
  if (!parts.isAsWritten) return parts.lastName;
  // ", Magnus": nothing before the comma, as these labels always read it.
  if (parts.name.contains(',')) return '';
  final words = parts.name.split(' ');
  if (words.length >= 2 && _kLoneInitial.hasMatch(words.last)) {
    return words[words.length - 2];
  }
  return words.last;
}

const DesktopCompactPlayerNameParts _kEmptyPlayerNameParts =
    DesktopCompactPlayerNameParts(lastName: '', firstInitial: '');

/// Upper-case only, so a surname such as "Im" is never read as a title.
final RegExp _kLeadingTitle = RegExp(
  r'^(?:GM|IM|FM|CM|NM|WGM|WIM|WFM|WCM|WNM)\.?\s+(?=\S)',
);
final RegExp _kTrailingParenthetical = RegExp(r'\s*\([^()]*\)$');
final RegExp _kWhitespace = RegExp(r'\s+');

/// `D`, `D.`, `S.L.`: a single initial or a run of dotted initials.
final RegExp _kInitialToken = RegExp(r'^\p{L}(?:\.\p{L})*\.?$', unicode: true);
final RegExp _kLoneInitial = RegExp(r'^\p{L}\.?$', unicode: true);

/// A name word: letters plus apostrophes, hyphens and dots ("Gukesh",
/// "O'Sullivan", "Vachier-Lagrave"). Rule 3 also needs two letters.
final RegExp _kNameWordToken = RegExp(r"^[\p{L}\p{M}'’.-]+$", unicode: true);
final RegExp _kLetter = RegExp(r'\p{L}', unicode: true);

String _initialOf(String text) =>
    _kLetter.firstMatch(text)?.group(0)?.toUpperCase() ?? '';

DesktopCompactPlayerNameParts _parseDesktopPlayerName(String value) {
  var name = value.replaceAll(_kWhitespace, ' ').trim();
  if (name.isEmpty) return _kEmptyPlayerNameParts;
  name = name.replaceFirst(_kLeadingTitle, '');

  // A trailing "(IND)" is noise. A comma inside it does not make a
  // "Surname, Given" name, so the comma test runs on the name without it.
  final stripped = name.replaceFirst(_kTrailingParenthetical, '').trim();
  final withoutSuffix = stripped.isEmpty ? name : stripped;
  final comma = withoutSuffix.indexOf(',');

  if (comma >= 0) {
    final lastName = withoutSuffix.substring(0, comma).trim();
    if (lastName.isEmpty) {
      return DesktopCompactPlayerNameParts(
        lastName: name,
        firstInitial: '',
        name: name,
        isAsWritten: true,
      );
    }
    return DesktopCompactPlayerNameParts(
      lastName: lastName,
      firstInitial: _initialOf(withoutSuffix.substring(comma + 1)),
      name: name,
    );
  }

  final base = withoutSuffix;
  final tokens = base.split(' ');
  if (tokens.length < 2) {
    return DesktopCompactPlayerNameParts(
      lastName: base,
      firstInitial: '',
      name: base,
    );
  }

  final words = <String>[];
  final initials = <String>[];
  var readable = true;
  for (final token in tokens) {
    if (_kInitialToken.hasMatch(token)) {
      initials.add(token);
    } else if (_kNameWordToken.hasMatch(token) &&
        _kLetter.allMatches(token).length >= 2) {
      words.add(token);
    } else {
      readable = false;
      break;
    }
  }
  if (readable && words.length == 1 && initials.isNotEmpty) {
    return DesktopCompactPlayerNameParts(
      lastName: words.single,
      firstInitial: _initialOf(initials.first),
      name: base,
    );
  }

  // Rule 4. The guess below is the one this parser has always made; only the
  // surname-only labels and the card overflow fallback still read it.
  final trailing = tokens.last.replaceAll('.', '');
  if (trailing.characters.length == 1) {
    return DesktopCompactPlayerNameParts(
      lastName: tokens.take(tokens.length - 1).join(' '),
      firstInitial: trailing.toUpperCase(),
      name: base,
      isAsWritten: true,
    );
  }
  return DesktopCompactPlayerNameParts(
    lastName: tokens.last,
    firstInitial: _initialOf(tokens.first),
    name: base,
    isAsWritten: true,
  );
}

/// One-line compact player name with a single-dot overflow contract.
///
/// The complete label ([DesktopCompactPlayerNameParts.displayLabel]: `Last, F.`,
/// or a name the rules cannot read as written) is shown whenever it fits. If
/// it does not, the surname alone is clipped at the longest measured prefix
/// that fits followed by one period. This deliberately avoids Flutter's
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
    final fullLabel =
        parts.displayLabel.isEmpty ? fallback : parts.displayLabel;
    // Measure in the font the Text below will draw with: [style] alone may
    // lack the inherited family, and a narrower stand-in font says a name
    // fits that then gets clipped mid-letter.
    final drawn = DefaultTextStyle.of(context).style.merge(style);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final display =
            maxWidth.isFinite &&
                    maxWidth > 0 &&
                    !_fits(context, fullLabel, maxWidth: maxWidth, style: drawn)
                ? _singleDotSurname(
                  context,
                  parts.lastName.isEmpty ? fallback : parts.lastName,
                  maxWidth: maxWidth,
                  style: drawn,
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
    this.color = kPrimaryColor,
  });

  final String title;
  final bool compact;

  /// The brand cyan by default; a neutral tone on a card drawn locked.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      title.trim(),
      maxLines: 1,
      overflow: TextOverflow.fade,
      softWrap: false,
      style: TextStyle(
        color: color,
        fontSize: compact ? 9.5 : 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
    );
  }
}
