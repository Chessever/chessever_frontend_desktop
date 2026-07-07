import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/chess_title_utils.dart';
import 'package:chessever/utils/local_pgn_metadata.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'package:chessever/widgets/skeleton_widget.dart';

const _kTitleStyle = TextStyle(
  color: kLightYellowColor,
  fontSize: 11,
  fontWeight: FontWeight.w700,
  height: 1.1,
);
const double _kLibraryPlayerFlagGap = 6;
const double _kLibraryPlayerTitleGap = 4;
const double _kLibraryPlayerRatingGap = 5;

/// Player cell for the local games table: federation flag + title + name.
///
/// Renders identically to the shared library table player cell
/// ([LibraryTablePlayerCell]) — same flag size, title style and abbreviated
/// name format — so imported databases match the cloud/TWIC tables next to
/// them. The one difference is that TWIC-style exports carry
/// `WhiteTitle`/`WhiteFideId` but no country tag, so both the flag and the
/// title resolve on demand through the chess_players FIDE-ID lookup (repo-level
/// per-ID cache, negative hits included) while a shimmer holds the title slot.
/// Import itself never waits on this.
class LocalGamePlayerCell extends ConsumerWidget {
  const LocalGamePlayerCell({
    super.key,
    required this.metadata,
    required this.side,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.rating = '',
  });

  final Map<String, dynamic> metadata;
  final String side;
  final EdgeInsetsGeometry padding;

  /// Optional trailing inline rating (e.g. `1774`). Rendered like the shared
  /// [LibraryTablePlayerCell] so the compact mini-preview table — which folds
  /// the Elo into the player column instead of a separate Elo column — matches
  /// the cloud/TWIC mini previews. Blank hides it (the wide full-table view
  /// keeps its dedicated Elo columns and leaves this empty).
  final String rating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawName = metadata[side]?.toString().trim() ?? '';
    final hasName = rawName.isNotEmpty && rawName != '?';
    final fideId = localPgnFideId(metadata, side);
    final titleChip = _buildTitleChip(ref, fideId);

    return Padding(
      padding: padding,
      child: Row(
        children: [
          BackfilledFederationFlag(
            federation: localPgnFederation(metadata, side),
            fideId: fideId,
            playerName: hasName ? rawName : null,
            width: 18,
            height: 13,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(width: _kLibraryPlayerFlagGap),
          if (titleChip != null) ...[
            titleChip,
            const SizedBox(width: _kLibraryPlayerTitleGap),
          ],
          Expanded(
            child: Text(
              hasName ? libraryStandardTablePlayerName(rawName) : side,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                height: 1.1,
                letterSpacing: 0,
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
      ),
    );
  }

  Widget? _buildTitleChip(WidgetRef ref, int? fideId) {
    final tagTitle = ChessTitleUtils.normalize(localPgnTitle(metadata, side));
    if (tagTitle.isNotEmpty) return _titleText(tagTitle);
    if (fideId == null) return null;
    return ref
        .watch(chessPlayerByFideIdProvider(fideId))
        .when<Widget?>(
          data: (player) {
            final resolved = ChessTitleUtils.normalize(player?.title ?? '');
            return resolved.isEmpty ? null : _titleText(resolved);
          },
          error: (_, _) => null,
          loading:
              () =>
                  const SkeletonWidget(child: Text('GM', style: _kTitleStyle)),
        );
  }

  Widget _titleText(String title) {
    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _kTitleStyle,
    );
  }
}
