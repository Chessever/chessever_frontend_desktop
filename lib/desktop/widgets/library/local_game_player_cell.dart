import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/chess_title_utils.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

/// Resolves the federation for one side ('White'/'Black') from a local PGN
/// header bag. PGN has no standard country tag, so probe the suffixes seen in
/// the wild.
String localPgnFederation(Map<String, dynamic> metadata, String side) {
  for (final suffix in const <String>[
    'Federation',
    'Fed',
    'Country',
    'TeamCountry',
    'Flag',
  ]) {
    final value = metadata['$side$suffix']?.toString().trim() ?? '';
    if (value.isNotEmpty && value != '?' && value != '-') return value;
  }
  return '';
}

/// Player cell for the local games table: federation flag + title + name.
///
/// TWIC-style exports carry `WhiteTitle`/`WhiteFideId` but no country tag, so
/// the flag resolves through [BackfilledFederationFlag]'s chess_players
/// FIDE-ID (then exact-name) lookup and collapses to nothing when unknown.
class LocalGamePlayerCell extends StatelessWidget {
  const LocalGamePlayerCell({
    super.key,
    required this.metadata,
    required this.side,
  });

  final Map<String, dynamic> metadata;
  final String side;

  @override
  Widget build(BuildContext context) {
    String meta(String key) => metadata[key]?.toString().trim() ?? '';
    final rawName = meta(side);
    final hasName = rawName.isNotEmpty && rawName != '?';
    final title = ChessTitleUtils.normalize(meta('${side}Title'));
    final fideId = int.tryParse(meta('${side}FideId'));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          BackfilledFederationFlag(
            federation: localPgnFederation(metadata, side),
            fideId: fideId != null && fideId > 0 ? fideId : null,
            playerName: hasName ? rawName : null,
            width: 18,
            height: 12,
            borderRadius: BorderRadius.circular(2),
          ),
          if (title.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kPrimaryColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                height: 1.1,
              ),
            ),
          ],
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              hasName ? rawName : side,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 12,
                height: 1.1,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
