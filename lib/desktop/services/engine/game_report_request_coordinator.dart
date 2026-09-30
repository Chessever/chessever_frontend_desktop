import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/game_report_allowance.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

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

  /// The account's lifetime free report is spent and no upgrade completed.
  quotaExceeded,

  /// The claim could not be answered. Retry, never a purchase prompt.
  temporarilyUnavailable,
}

@immutable
class GameReportRequestResult {
  const GameReportRequestResult(this.outcome, {this.reason, this.message});

  final GameReportRequestOutcome outcome;

  /// Stable machine-readable reason for logs/tests.
  final String? reason;
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
  String toString() => 'GameReportRequestResult($outcome, $reason)';
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

  /// Opens the paywall. Resolves true when the user subscribed.
  final Future<bool> Function()? requestUpgrade;

  /// Re-reads the entitlement after a purchase, before claiming again.
  final Future<void> Function()? refreshEntitlement;
}

/// Whether [headers] (or the game's own tags) record a finished result.
bool gameReportHasFinalResult(ChessGame game, Map<String, String> headers) {
  final raw =
      (headers['Result'] ?? game.metadata['Result']?.toString() ?? '').trim();
  return raw == '1-0' || raw == '0-1' || raw == '1/2-1/2' || raw == '½-½';
}

/// The one path every report entry point uses: Analyze, Retry, and any
/// alternate trigger. The order is fixed:
///
/// 1. validate the game (source access, finished, nonempty mainline);
/// 2. require an account and serialize this account's requests in-process so
///    two tabs cannot both consume the one free success;
/// 3. restore a completed session report or account-scoped cached report only
///    when this account has explicitly admitted that fingerprint. A first
///    explicit cache hit can spend the free success;
/// 4. generate only when Premium is verified or the lifetime free success is
///    still unused. Failed/cancelled analysis writes no success marker;
/// 5. after an upgrade, refresh the entitlement and re-check before
///    generating.
class GameReportRequestCoordinator {
  GameReportRequestCoordinator({
    required String? Function() accountId,
    required bool Function() isPremium,
    Object? Function()? accountEpoch,
    bool Function()? entitlementKnown,
    GameAnalysisReportStore? store,
    GameReportAllowanceStore? allowanceStore,
  }) : _accountId = accountId,
       _isPremium = isPremium,
       _accountEpoch = accountEpoch ?? accountId,
       _entitlementKnown = entitlementKnown ?? _alwaysCurrent,
       _store = store ?? GameAnalysisReportStore.instance,
       _allowanceStore = allowanceStore ?? GameReportAllowanceStore.instance;

  final String? Function() _accountId;
  final bool Function() _isPremium;
  final Object? Function() _accountEpoch;
  final bool Function() _entitlementKnown;
  final GameAnalysisReportStore _store;
  final GameReportAllowanceStore _allowanceStore;
  static final Map<String, Future<void>> _accountChains = {};
  static bool _alwaysCurrent() => true;
  static const _stale = GameReportRequestResult(
    GameReportRequestOutcome.temporarilyUnavailable,
    reason: 'stale_request',
    message: 'Start the report again from the current game.',
  );
  static const _retry = GameReportRequestResult(
    GameReportRequestOutcome.temporarilyUnavailable,
    message: "Couldn't check your report allowance.",
  );

  Future<GameReportRequestResult> request({
    required GameAnalysisReportController controller,
    required ChessGame? game,
    required bool gameFinished,
    bool sourceAccessible = true,
    int? whiteRating,
    int? blackRating,
    bool Function() isCurrent = _alwaysCurrent,
    GameReportRequestUi ui = const GameReportRequestUi(),
  }) async {
    if (!isCurrent()) return _stale;
    if (controller.state.isRunning) {
      return const GameReportRequestResult(GameReportRequestOutcome.busy);
    }
    if (!sourceAccessible ||
        game == null ||
        game.mainline.isEmpty ||
        !gameFinished) {
      return const GameReportRequestResult(
        GameReportRequestOutcome.unavailable,
        message: 'Load an accessible finished game with moves.',
      );
    }
    var account = _accountId();
    if (account == null || account.isEmpty) {
      if (ui.requestAccount == null ||
          !await ui.requestAccount!() ||
          !isCurrent()) {
        return const GameReportRequestResult(
          GameReportRequestOutcome.accountRequired,
        );
      }
      account = _accountId();
    }
    if (account == null || account.isEmpty) {
      return const GameReportRequestResult(
        GameReportRequestOutcome.accountRequired,
      );
    }
    final owner = account;
    final epoch = _accountEpoch();
    final fingerprint = gameReportFingerprint(game);
    bool current() =>
        isCurrent() &&
        _accountId() == owner &&
        _accountEpoch() == epoch &&
        gameReportFingerprint(game) == fingerprint;

    return _runSerialized(owner, () async {
      try {
        if (!current()) return _stale;
        final admitted = await _allowanceStore.hasAdmittedReport(
          owner,
          fingerprint,
        );
        if (!current()) return _stale;
        final shown = controller.state;
        final sessionReport =
            shown.status == GameReportStatus.completed &&
                    shown.report?.fingerprint == fingerprint
                ? shown.report
                : null;
        final cached = sessionReport ?? await _store.load(owner, fingerprint);
        if (!current()) return _stale;
        if (admitted && cached != null) {
          if (sessionReport == null &&
              !controller.adoptCompletedReport(cached)) {
            return const GameReportRequestResult(GameReportRequestOutcome.busy);
          }
          return const GameReportRequestResult(
            GameReportRequestOutcome.restored,
          );
        }

        // Previously admitted reports may be recomputed after cache eviction;
        // new fingerprints require the lifetime allowance or verified Premium.
        var premiumAdmission = _isPremium();
        if (!admitted && !premiumAdmission) {
          final spent = await _allowanceStore.hasLifetimeSuccess(owner);
          if (!current()) return _stale;
          if (spent) {
            if (!_entitlementKnown()) return _retry;
            if (ui.requestUpgrade == null || !await ui.requestUpgrade!()) {
              if (!current()) return _stale;
              return const GameReportRequestResult(
                GameReportRequestOutcome.quotaExceeded,
                reason: 'lifetime_free_success_used',
              );
            }
            if (!current()) return _stale;
            await ui.refreshEntitlement?.call();
            if (!current()) return _stale;
            if (!_isPremium()) {
              return const GameReportRequestResult(
                GameReportRequestOutcome.quotaExceeded,
                reason: 'lifetime_free_success_used',
              );
            }
            premiumAdmission = true;
          }
        }
        if (!current()) return _stale;
        if (cached != null) {
          if (!controller.adoptCompletedReport(cached)) {
            return const GameReportRequestResult(GameReportRequestOutcome.busy);
          }
        } else {
          await controller.analyze(
            game,
            whiteRating: whiteRating,
            blackRating: blackRating,
          );
        }
        if (!current()) return _stale;
        final state = controller.state;
        final report = state.report;
        if (state.status != GameReportStatus.completed ||
            report == null ||
            report.fingerprint != fingerprint) {
          // Failure/cancellation releases the in-process reservation unspent.
          return const GameReportRequestResult(
            GameReportRequestOutcome.generated,
            reason: 'not_delivered',
          );
        }
        if (!admitted) {
          // Await durable admission before releasing the queue to another tab.
          if (premiumAdmission) {
            await _allowanceStore.markReportAdmitted(owner, fingerprint);
          } else {
            await _allowanceStore.markFreeSuccess(owner, fingerprint);
          }
        }
        // Keep the success marker even if the optional report cache fails.
        try {
          await _store.save(owner, report);
        } catch (_) {}
        if (!current()) return _stale;
        return GameReportRequestResult(
          cached == null
              ? GameReportRequestOutcome.generated
              : GameReportRequestOutcome.restored,
          reason:
              admitted
                  ? 'already_admitted'
                  : premiumAdmission
                  ? 'premium'
                  : 'free_success',
        );
      } catch (error) {
        debugPrint('[GameReport] admission unavailable: ${error.runtimeType}');
        return _retry;
      }
    });
  }

  static Future<T> _runSerialized<T>(
    String account,
    Future<T> Function() action,
  ) {
    final previous = _accountChains[account] ?? Future<void>.value();
    final completer = Completer<void>();
    final gate = previous.catchError((_) {}).then((_) => completer.future);
    _accountChains[account] = gate;
    return previous.catchError((_) {}).then((_) => action()).whenComplete(() {
      completer.complete();
      if (identical(_accountChains[account], gate)) {
        _accountChains.remove(account);
      }
    });
  }
}
