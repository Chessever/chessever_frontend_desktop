import 'package:chessever/desktop/auth/desktop_quota_queue.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';

/// Serialize the reused fresh-count/add path within this process. Removal is
/// never gated. Cross-process/device atomic enforcement remains server-owned.
class DesktopFavoritePlayersNotifier extends FavoritePlayersNotifierNew {
  int _generation = 0;
  @override
  Future<List<FavoritePlayer>> build() {
    _generation++;
    ref.onDispose(() => _generation++);
    return super.build();
  }

  static final _adds = DesktopQuotaQueue();
  @override
  Future<void> addFavorite({
    String? fideId,
    required String playerName,
    String? countryCode,
    int? rating,
    String? title,
    String? gamebasePlayerId,
    String? memorialSourceIdentity,
    String? memorialRouteId,
  }) {
    final account = Supabase.instance.client.auth.currentUser?.id;
    final generation = _generation;
    return _adds.run(() async {
      if (generation != _generation) {
        throw StateError('Favorite request expired. Retry.');
      }
      if (account == null ||
          Supabase.instance.client.auth.currentUser?.id != account) {
        throw StateError('Sign in again before adding favorites.');
      }
      final status = ref.read(desktopPremiumAccessProvider);
      if (status != DesktopAccess.allowed) {
        final count = await Supabase.instance.client
            .from('user_favorite_players')
            .count(CountOption.exact)
            .eq('user_id', account);
        if (Supabase.instance.client.auth.currentUser?.id != account ||
            (!desktopQuotaFits(count, 1, desktopFreeFavoritePlayers) &&
                ref.read(desktopPremiumAccessProvider) !=
                    DesktopAccess.allowed)) {
          throw const DesktopPremiumRequiredException();
        }
      }
      await super.addFavorite(
        fideId: fideId,
        playerName: playerName,
        countryCode: countryCode,
        rating: rating,
        title: title,
        gamebasePlayerId: gamebasePlayerId,
        memorialSourceIdentity: memorialSourceIdentity,
        memorialRouteId: memorialRouteId,
      );
    });
  }
}

final desktopFavoritePlayersOverride = favoritePlayersProviderNew.overrideWith(
  DesktopFavoritePlayersNotifier.new,
);
