import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/repository/supabase/game_analysis_quota_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// Claims a report slot: `public.claim_game_analysis_report(p_fingerprint)`.
typedef GameReportClaim =
    Future<GameAnalysisClaimResult> Function(String fingerprint);

enum GameReportRequestOutcome {
  /// A report for this exact mainline was already on screen or cached.
  /// No claim was made.
  restored,

  /// The claim was affirmative and generation ran. It may still have ended
  /// cancelled or failed; the controller's state says which.
  generated,

  /// A report was already running for this tab.
  busy,

  /// Nothing to analyse: no game, no mainline, no result yet, or the game's
  /// source is not open to this account.
  unavailable,
  accountRequired,

  /// Today's free report is spent and no upgrade completed.
  quotaExceeded,

  /// The claim could not be answered. Retry, never a purchase prompt.
  temporarilyUnavailable,
}

@immutable
class GameReportRequestResult {
  const GameReportRequestResult(this.outcome, {this.claimReason, this.message});

  final GameReportRequestOutcome outcome;

  /// The server's last `reason`, when a claim was made.
  final String? claimReason;
  final String? message;

  /// Whether the request ended without a report and needs to explain why.
  bool get isBlocked => switch (outcome) {
    GameReportRequestOutcome.unavailable ||
    GameReportRequestOutcome.accountRequired ||
    GameReportRequestOutcome.quotaExceeded ||
    GameReportRequestOutcome.temporarilyUnavailable => true,
    _ => false,
  };

  @override
  String toString() => 'GameReportRequestResult($outcome, $claimReason)';
}

/// Interactive steps a denial may take. Every callback runs only in the
/// foreground window that initiated the request.
@immutable
class GameReportRequestUi {
  const GameReportRequestUi({
    this.requestAccount,
    this.requestUpgrade,
    this.refreshEntitlement,
  });

  /// Offers sign-in. Resolves true when an account is now available.
  final Future<bool> Function()? requestAccount;

  /// Opens the paywall for [denial]. Resolves true when the user subscribed.
  final Future<bool> Function(GameAnalysisClaimResult denial)? requestUpgrade;

  /// Re-reads the entitlement after a purchase, before claiming again.
  final Future<void> Function()? refreshEntitlement;
}

/// Whether [headers] (or the game's own tags) record a finished result.
bool gameReportHasFinalResult(ChessGame game, Map<String, String> headers) {
  final raw = (headers['Result'] ?? game.metadata['Result']?.toString() ?? '')
      .trim();
  return raw == '1-0' || raw == '0-1' || raw == '1/2-1/2' || raw == '½-½';
}

/// The one path every report entry point uses: Analyze, Retry, and any
/// alternate trigger. The order is fixed:
///
/// 1. validate the game (source access, finished, nonempty mainline);
/// 2. restore a completed session report or an account-scoped cached report,
///    which never spends a claim and works offline;
/// 3. otherwise call `claim_game_analysis_report` with the cross-platform
///    fingerprint;
/// 4. generate only after an affirmative claim. Server first, then the local
///    engine: the local fallback lives inside the controller's `analyze`,
///    which is unreachable from here without an allowed claim;
/// 5. after an upgrade, refresh the entitlement and claim again before
///    generating.
class GameReportRequestCoordinator {
  GameReportRequestCoordinator({
    required GameReportClaim claim,
    required String? Function() accountId,
    GameAnalysisReportStore? store,
  }) : _claim = claim,
       _accountId = accountId,
       _store = store ?? GameAnalysisReportStore.instance;

  final GameReportClaim _claim;
  final String? Function() _accountId;
  final GameAnalysisReportStore _store;

  Future<GameReportRequestResult> request({
    required GameAnalysisReportController controller,
    required ChessGame? game,
    required bool gameFinished,
    bool sourceAccessible = true,
    int? whiteRating,
    int? blackRating,
    GameReportRequestUi ui = const GameReportRequestUi(),
  }) async {
    // 1. Validate. Nothing expensive starts for a request that cannot run.
    if (controller.state.isRunning) {
      return const GameReportRequestResult(GameReportRequestOutcome.busy);
    }
    if (!sourceAccessible) {
      return const GameReportRequestResult(
        GameReportRequestOutcome.unavailable,
        message: 'Reports are not available for games from this source.',
      );
    }
    if (game == null || game.mainline.isEmpty) {
      return const GameReportRequestResult(
        GameReportRequestOutcome.unavailable,
        message: 'Load a game with at least one move.',
      );
    }
    if (!gameFinished) {
      return const GameReportRequestResult(
        GameReportRequestOutcome.unavailable,
        message: 'Reports are available once the game has a result.',
      );
    }
    final fingerprint = gameReportFingerprint(game);

    // 2. Restore. A completed report is never paid for twice.
    final shown = controller.state;
    if (shown.status == GameReportStatus.completed &&
        shown.report?.fingerprint == fingerprint) {
      return const GameReportRequestResult(GameReportRequestOutcome.restored);
    }
    final account = _accountId();
    if (account != null && account.isNotEmpty) {
      final cached = await _store.load(account, fingerprint);
      if (cached != null && controller.adoptCompletedReport(cached)) {
        return const GameReportRequestResult(
          GameReportRequestOutcome.restored,
        );
      }
    }

    // 3. Claim.
    var claim = await _claimOrNull(fingerprint);
    if (claim == null) return _unavailableClaim;

    if (!claim.allowed && claim.needsAuth) {
      final requestAccount = ui.requestAccount;
      if (requestAccount == null || !await requestAccount()) {
        return GameReportRequestResult(
          GameReportRequestOutcome.accountRequired,
          claimReason: claim.reason,
        );
      }
      claim = await _claimOrNull(fingerprint);
      if (claim == null) return _unavailableClaim;
    }

    // 5. Upgrade, refresh, claim again. The paywall's answer is never trusted
    // on its own: only a second affirmative claim unlocks generation.
    if (!claim.allowed && claim.dailyLimitReached) {
      final requestUpgrade = ui.requestUpgrade;
      if (requestUpgrade == null || !await requestUpgrade(claim)) {
        return GameReportRequestResult(
          GameReportRequestOutcome.quotaExceeded,
          claimReason: claim.reason,
        );
      }
      try {
        await ui.refreshEntitlement?.call();
      } catch (error) {
        debugPrint('[GameReport] entitlement refresh failed: $error');
      }
      claim = await _claimOrNull(fingerprint);
      if (claim == null) return _unavailableClaim;
    }

    if (!claim.allowed) {
      return GameReportRequestResult(
        claim.dailyLimitReached
            ? GameReportRequestOutcome.quotaExceeded
            : claim.needsAuth
            ? GameReportRequestOutcome.accountRequired
            : GameReportRequestOutcome.temporarilyUnavailable,
        claimReason: claim.reason,
      );
    }

    // 4. Generate. From here the day's slot is spent: cancelling, closing the
    // tab or a failed run does NOT refund it. There is deliberately no refund
    // path; retrying the same game today is free (`same_day_same_game`).
    await controller.analyze(
      game,
      whiteRating: whiteRating,
      blackRating: blackRating,
    );
    final finished = controller.state;
    final report = finished.report;
    if (account != null &&
        account.isNotEmpty &&
        finished.status == GameReportStatus.completed &&
        report != null &&
        report.fingerprint == fingerprint) {
      unawaited(
        _store.save(account, report).catchError((Object error) {
          debugPrint('[GameReport] cache save failed: $error');
        }),
      );
    }
    return GameReportRequestResult(
      GameReportRequestOutcome.generated,
      claimReason: claim.reason,
    );
  }

  static const _unavailableClaim = GameReportRequestResult(
    GameReportRequestOutcome.temporarilyUnavailable,
    message: "Couldn't check your report allowance.",
  );

  Future<GameAnalysisClaimResult?> _claimOrNull(String fingerprint) async {
    try {
      return await _claim(fingerprint);
    } catch (error) {
      debugPrint('[GameReport] claim failed: $error');
      return null;
    }
  }
}
