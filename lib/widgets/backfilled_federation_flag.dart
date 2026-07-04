import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// [FederationFlag] variant that resolves the flag from Supabase's
/// `chess_players` table when the supplied federation is missing.
///
/// Event/broadcast federation remains the source of truth when present and
/// valid. If the broadcast omits a flag (or sends a known unknown marker such
/// as `?`), we fall back to the matched ChessEver player profile by FIDE ID and
/// then by exact normalized name.
///
/// `FID`/`FIDE` is treated as a "no national federation known" marker: we still
/// try to resolve the player's real country first (so enrichment keeps winning),
/// and only when no country resolves do we fall through to the bundled FIDE mark
/// instead of hiding the flag. Genuine unknowns (empty, `?`) stay hidden.
class BackfilledFederationFlag extends ConsumerWidget {
  const BackfilledFederationFlag({
    super.key,
    required this.federation,
    required this.fideId,
    this.playerName,
    this.width,
    this.height,
    this.borderRadius,
  });

  final String? federation;
  final int? fideId;
  final String? playerName;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  bool _isFideMarker(String value) {
    final upper = value.toUpperCase();
    return upper == 'FID' || upper == 'FIDE';
  }

  bool _needsBackfill(String value) {
    if (value.isEmpty) return true;
    final upper = value.toUpperCase();
    // '?' is unknown/missing. FID/FIDE is often a placeholder for "no national
    // federation known", so we still try country backfill first and only fall
    // back to the FIDE mark when nothing resolves.
    return upper == '?' || _isFideMarker(value);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raw = (federation ?? '').trim();
    var resolved = raw;

    if (_needsBackfill(raw)) {
      var country = '';
      if (fideId != null && fideId! > 0) {
        final async = ref.watch(chessPlayerByFideIdProvider(fideId));
        country = async.valueOrNull?.country?.trim() ?? '';
      }
      if (country.isEmpty && (playerName?.trim().isNotEmpty ?? false)) {
        final async = ref.watch(chessPlayerByNameProvider(playerName!.trim()));
        country = async.valueOrNull?.country?.trim() ?? '';
      }
      if (country.isNotEmpty) {
        resolved = country;
      } else if (_isFideMarker(raw)) {
        // No national federation resolved for an explicit FIDE marker: show the
        // bundled FIDE mark rather than hiding it.
        resolved = raw;
      } else {
        return const SizedBox.shrink();
      }
    }

    return FederationFlag(
      federation: resolved,
      width: width,
      height: height,
      borderRadius: borderRadius,
    );
  }
}
