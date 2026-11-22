import 'package:flutter/material.dart';

import 'package:chessever/desktop/widgets/table_display_value.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

/// Shared row vocabulary for every desktop **library-page** games table
/// (`_GamesTableRow`, `_DatabaseSavedGameRow`, `_TwicTableRow` and the local
/// imported-database table). Keeping these in one place is what guarantees an
/// imported PGN database renders its rows *identically* to the cloud / TWIC
/// databases sitting next to it in the Library.

const double _kLibraryPlayerFlagGap = 6;
const double _kLibraryPlayerTitleGap = 4;
const double _kLibraryPlayerRatingGap = 5;

/// Whether a White/Black value reads as a person's name rather than a study,
/// repertoire or variation label.
///
/// An imported PGN is not always two people playing: a repertoire keeps the
/// variation path in White and a label in Black (`Botvinnik / 12.Bf6` against
/// `Main Line`). Abbreviating those turns a row into `12.Bf6, B.` versus
/// `Line, M.` and hides which line it is, so anything carrying notation
/// marks, digits, punctuation-only words or more than three words is left
/// alone.
bool libraryPlayerNameIsPersonal(String raw) {
  final name = desktopTablePlayerValue(raw);
  if (name.isEmpty) return false;
  if (name.contains(RegExp(r'''[/\\()\[\]{}!?<>+=*;:"“”]'''))) return false;
  if (RegExp(r'\d').hasMatch(name)) return false;
  final tokens = name.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (tokens.length > 3) return false;
  // Every word needs a letter: a stray `-` or `+` between words is a label.
  final word = RegExp(r"^[A-Za-zÀ-ÖØ-öø-ÿ'’-]+,?\.?$");
  return tokens.every(word.hasMatch);
}

/// Standard-table player name abbreviation: `Carlsen, Magnus` → `Carlsen, M.`.
String libraryStandardTablePlayerName(String raw) {
  final name = desktopTablePlayerValue(raw);
  if (name.isEmpty) return '';
  if (!libraryPlayerNameIsPersonal(name)) return name;

  String initial(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    return '${trimmed.characters.first.toUpperCase()}.';
  }

  if (name.contains(',')) {
    final parts = name.split(',');
    final last = parts.first.trim();
    final first = parts.skip(1).join(',').trim();
    final firstInitial = initial(first);
    if (last.isEmpty) return firstInitial.isEmpty ? name : firstInitial;
    return firstInitial.isEmpty ? last : '$last, $firstInitial';
  }

  final tokens = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (tokens.length < 2) return name;
  // FIDE records a mononym player as "Gukesh D": the trailing letter is the
  // initial, so the name stays "Gukesh, D.", never "D, G.".
  final trailing = tokens.last.replaceAll('.', '');
  if (trailing.characters.length == 1) {
    return '${tokens.take(tokens.length - 1).join(' ')}, ${initial(trailing)}';
  }
  final last = tokens.last;
  final firstInitial = initial(tokens.first);
  return firstInitial.isEmpty ? last : '$last, $firstInitial';
}

/// Federation flag + optional title + abbreviated player name (+ optional
/// trailing inline rating). This is the canonical library player cell.
class LibraryTablePlayerCell extends StatelessWidget {
  const LibraryTablePlayerCell({
    super.key,
    required this.name,
    required this.federation,
    this.fideId,
    required this.title,
    this.rating = '',
    this.abbreviate = true,
  });

  final String name;
  final String federation;
  final int? fideId;
  final String title;
  final String rating;

  /// `Last, F.` may fall back to the compact form, but never by default: the
  /// cell shows what the row says whenever its column has room, and only
  /// shortens a real name when it does not. Pass false where the name must
  /// never be shortened at all.
  final bool abbreviate;

  static const TextStyle _kNameStyle = TextStyle(
    color: kWhiteColor,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    final fullName = desktopTablePlayerValue(name);
    if (fullName.isEmpty) return const SizedBox.shrink();
    final compactName =
        abbreviate ? libraryStandardTablePlayerName(name) : fullName;
    // In a very narrow column the rating, then the title, give way so the
    // name keeps room instead of the row spilling into the next column.
    return LayoutBuilder(
      builder: (context, constraints) {
        final showRating = constraints.maxWidth >= 120;
        final showTitle = constraints.maxWidth >= 80;
        return Row(
          children: [
            BackfilledFederationFlag(
              federation: federation.isEmpty ? null : federation,
              fideId: fideId,
              width: 18,
              height: 13,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(width: _kLibraryPlayerFlagGap),
            if (title.isNotEmpty && showTitle) ...[
              Text(
                title,
                style: const TextStyle(
                  color: kLightYellowColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: _kLibraryPlayerTitleGap),
            ],
            Expanded(
              child: LayoutBuilder(
                // The room the name actually has, after the flag, title and
                // rating: `Carlsen, Magnus` stays whole whenever it fits, and
                // only a column too narrow for it falls back to `Carlsen, M.`.
                builder: (context, nameConstraints) => Text(
                  _libraryFittedPlayerName(
                    full: fullName,
                    compact: compactName,
                    available: nameConstraints.maxWidth,
                    style: _kNameStyle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _kNameStyle,
                ),
              ),
            ),
            if (rating.trim().isNotEmpty && showRating) ...[
              const SizedBox(width: _kLibraryPlayerRatingGap),
              Text(
                rating.trim(),
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The full value when the cell has room for it, `Last, F.` when it does not.
///
/// Space decides, not the shape of the string: a wide column shows
/// `Magnus Carlsen` and a narrow one `Carlsen, M.`, and a study label that was
/// never a name (`Botvinnik / 12.Bf6`) is only ever ellipsized, never rewritten.
String _libraryFittedPlayerName({
  required String full,
  required String compact,
  required double available,
  required TextStyle style,
}) {
  if (full == compact) return full;
  if (!available.isFinite) return full;
  if (available <= 0) return compact;
  final painter = TextPainter(
    text: TextSpan(text: full, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width <= available ? full : compact;
}

/// Right-aligned rating cell (`—` when blank).
class LibraryTableRatingCell extends StatelessWidget {
  const LibraryTableRatingCell({super.key, required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    final value = desktopTableDisplayValue(rating);
    return Text(
      value,
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 11,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Boxed ECO code (`—` when blank).
class LibraryTableEcoCell extends StatelessWidget {
  const LibraryTableEcoCell({super.key, required this.eco});

  final String eco;

  @override
  Widget build(BuildContext context) {
    final value = desktopTableDisplayValue(eco);
    if (value.isEmpty) return const SizedBox.shrink();
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        value,
        style: const TextStyle(
          color: kWhiteColor,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Centered result glyph (`1 – 0`, `½ – ½`, …).
///
/// Colorful W/D/L palette aligned with players Overview:
/// white wins → brand primary, black wins → red, draws → slate.
class LibraryTableResultPill extends StatelessWidget {
  const LibraryTableResultPill({super.key, required this.result, this.color});

  final String result;

  /// Replaces the board-colour palette: a neutral tone on a locked row, or the
  /// outcome for one player on a single-player record.
  final Color? color;

  static const Color _kDraw = Color(0xFF8B93A7);

  @override
  Widget build(BuildContext context) {
    final r = desktopTableDisplayValue(result);
    final (label, paletteColor) = switch (r) {
      '1-0' => ('1 – 0', kPrimaryColor),
      '0-1' => ('0 – 1', kRedColor),
      '1/2-1/2' || '½-½' => ('½ – ½', _kDraw),
      '*' => ('', kLightGreyColor),
      _ => ('', kLightGreyColor),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Center(
      child: Text(
        label,
        style: TextStyle(
          color: color ?? paletteColor,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Selected/hover row decoration shared by every library-page table.
///
/// A selected row gets a 3px [kPrimaryColor] left accent bar plus a tint;
/// unselected/hover rows carry the same-width transparent left border so the
/// row content never shifts horizontally when selection moves.
BoxDecoration librarySelectedRowDecoration({
  required bool selected,
  required bool hovered,
  bool bottomDivider = true,
  double selectedTint = 0.20,
}) {
  return BoxDecoration(
    color:
        selected
            ? kPrimaryColor.withValues(alpha: selectedTint)
            : kBlack3Color.withValues(alpha: hovered ? 0.55 : 0),
    border: Border(
      left: BorderSide(
        color: selected ? kPrimaryColor : Colors.transparent,
        width: 3,
      ),
      bottom:
          bottomDivider
              ? const BorderSide(color: kDividerColor, width: 1)
              : BorderSide.none,
    ),
  );
}
