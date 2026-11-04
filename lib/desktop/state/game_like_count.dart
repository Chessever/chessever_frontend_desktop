import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_supabase_init.dart';

/// A game's community like count, keyed by `GamesTourModel.likeId`, straight
/// from the server (`public.game_like_count`, the same like definition the
/// Likes ranking counts). Same read as the phone's `gameLikeCountProvider`.
///
/// Null when unknown (signed out, offline, any error): the board's Like
/// button then shows a plain heart rather than a wrong number. Invalidate it
/// after a like write lands so the viewer's own like is counted.
final desktopGameLikeCountProvider = FutureProvider.autoDispose
    .family<int?, String>((ref, likeId) async {
      final id = likeId.trim();
      if (id.isEmpty || !DesktopSupabaseInit.isInitialized) return null;
      final client = Supabase.instance.client;
      if (client.auth.currentSession == null) return null;
      try {
        final result = await client.rpc(
          'game_like_count',
          params: {'p_source_game_id': id},
        );
        return parseDesktopGameLikeCount(result);
      } catch (error) {
        debugPrint('[LikeCount] $id failed: $error');
        return null;
      }
    });

/// The RPC answers a bare bigint, which PostgREST may send as a number or a
/// numeric string.
@visibleForTesting
int? parseDesktopGameLikeCount(Object? raw) {
  final value = switch (raw) {
    int v => v,
    num v when v.isFinite => v.toInt(),
    String v => int.tryParse(v.trim()),
    _ => null,
  };
  return value == null || value < 0 ? null : value;
}
