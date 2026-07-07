import 'package:flutter/material.dart';

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

/// Standard-table player name abbreviation: `Carlsen, Magnus` → `Carlsen, M.`.
String libraryStandardTablePlayerName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '—';

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
  });

  final String name;
  final String federation;
  final int? fideId;
  final String title;
  final String rating;

  @override
  Widget build(BuildContext context) {
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
        if (title.isNotEmpty) ...[
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
          child: Text(
            libraryStandardTablePlayerName(name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (rating.trim().isNotEmpty) ...[
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
  }
}

/// Right-aligned rating cell (`—` when blank).
class LibraryTableRatingCell extends StatelessWidget {
  const LibraryTableRatingCell({super.key, required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    return Text(
      rating.trim().isEmpty ? '—' : rating.trim(),
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
    final value = eco.trim();
    if (value.isEmpty || value == '?') {
      return const Text(
        '—',
        style: TextStyle(color: kLightGreyColor, fontSize: 11),
      );
    }
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
class LibraryTableResultPill extends StatelessWidget {
  const LibraryTableResultPill({super.key, required this.result});

  final String result;

  @override
  Widget build(BuildContext context) {
    final r = result.trim();
    final (label, color) = switch (r) {
      '1-0' => ('1 – 0', kWhiteColor),
      '0-1' => ('0 – 1', kWhiteColor),
      '1/2-1/2' || '½-½' => ('½ – ½', kWhiteColor70),
      '*' => ('•', kGreenColor),
      _ => ('—', kLightGreyColor),
    };
    return Center(
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
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
            : (hovered ? kBlack3Color.withValues(alpha: 0.55) : null),
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
