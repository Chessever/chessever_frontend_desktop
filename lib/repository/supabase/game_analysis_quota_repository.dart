import 'package:chessever/repository/supabase/base_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Server-authoritative result of claiming a free-tier report generation slot.
///
/// Ported from the phone app
/// (`chessever-frontend/lib/repository/supabase/game_analysis_quota_repository.dart`).
/// Reasons from `public.claim_game_analysis_report(p_fingerprint text)`:
/// `auth_required`, `invalid_fingerprint`, `premium`, `same_day_same_game`,
/// `daily_limit`, `claimed`.
class GameAnalysisClaimResult {
  const GameAnalysisClaimResult({
    required this.allowed,
    required this.reason,
    required this.isPremium,
  });

  final bool allowed;
  final String reason;
  final bool isPremium;

  bool get needsAuth => reason == 'auth_required';
  bool get dailyLimitReached => reason == 'daily_limit';

  factory GameAnalysisClaimResult.fromJson(Map<String, dynamic> json) {
    return GameAnalysisClaimResult(
      allowed: json['allowed'] as bool? ?? false,
      reason: (json['reason'] as String?) ?? 'unknown',
      isPremium: json['is_premium'] as bool? ?? false,
    );
  }

  static const deniedUnknown = GameAnalysisClaimResult(
    allowed: false,
    reason: 'unknown',
    isPremium: false,
  );

  @override
  String toString() =>
      'GameAnalysisClaimResult(allowed: $allowed, reason: $reason, '
      'isPremium: $isPremium)';
}

/// Calls [claim_game_analysis_report] so free users cannot bypass the daily cap
/// by editing the client. Failures throw; the caller treats them as Retry.
class GameAnalysisQuotaRepository extends BaseRepository {
  Future<GameAnalysisClaimResult> claim(String fingerprint) async {
    return handleApiCall(() async {
      final response = await supabase.rpc(
        'claim_game_analysis_report',
        params: {'p_fingerprint': fingerprint},
      );
      if (response is Map<String, dynamic>) {
        return GameAnalysisClaimResult.fromJson(response);
      }
      if (response is Map) {
        return GameAnalysisClaimResult.fromJson(
          Map<String, dynamic>.from(response),
        );
      }
      return GameAnalysisClaimResult.deniedUnknown;
    });
  }
}

final gameAnalysisQuotaRepositoryProvider =
    Provider<GameAnalysisQuotaRepository>(
      (ref) => GameAnalysisQuotaRepository(),
    );
