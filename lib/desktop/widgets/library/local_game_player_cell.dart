import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/chess_title_utils.dart';
import 'package:chessever/utils/local_pgn_metadata.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'package:chessever/widgets/skeleton_widget.dart';

const _kTitleStyle = TextStyle(
  color: kPrimaryColor,
  fontSize: 10,
  fontWeight: FontWeight.w800,
  height: 1.1,
);

/// Player cell for the local games table: federation flag + title + name.
///
/// TWIC-style exports carry `WhiteTitle`/`WhiteFideId` but no country tag, so
/// both the flag and the title resolve on demand through the chess_players
/// FIDE-ID lookup (repo-level per-ID cache, negative hits included) while a
/// shimmer holds the title slot. Import itself never waits on this.
class LocalGamePlayerCell extends ConsumerWidget {
  const LocalGamePlayerCell({
    super.key,
    required this.metadata,
    required this.side,
  });

  final Map<String, dynamic> metadata;
  final String side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawName = metadata[side]?.toString().trim() ?? '';
    final hasName = rawName.isNotEmpty && rawName != '?';
    final fideId = localPgnFideId(metadata, side);
    final titleChip = _buildTitleChip(ref, fideId);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          BackfilledFederationFlag(
            federation: localPgnFederation(metadata, side),
            fideId: fideId,
            playerName: hasName ? rawName : null,
            width: 18,
            height: 12,
            borderRadius: BorderRadius.circular(2),
          ),
          if (titleChip != null) ...[
            const SizedBox(width: 6),
            titleChip,
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
              () => const SkeletonWidget(child: Text('GM', style: _kTitleStyle)),
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
