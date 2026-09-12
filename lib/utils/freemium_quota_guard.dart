import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/repository/freemium/freemium_quota_repository.dart';
import 'package:chessever/widgets/paywall/premium_paywall_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Server-authorized admission for an explicit user action that adds
/// [additions] records of [kind] (Save, Favorite, Create database).
///
/// * Allowed, unavailable and account-required results return immediately.
///   Unavailable is never turned into a purchase prompt.
/// * A spent allowance publishes its capacity on
///   [freemiumQuotaDenialProvider] and opens the existing paywall entry point.
///   If the user subscribes there, the server is asked again: it re-reads the
///   entitlement itself, so the sheet's return value never grants a slot.
///
/// Must only be called from the foreground window's own action handler.
Future<FreemiumQuotaResult> requestFreemiumQuota(
  BuildContext context,
  FreemiumQuotaKind kind, {
  int additions = 1,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final repository = container.read(freemiumQuotaRepositoryProvider);
  final result = await repository.check(kind, additions: additions);
  if (result.outcome != FreemiumQuotaOutcome.quotaExceeded ||
      !context.mounted) {
    return result;
  }

  final denial = container.read(freemiumQuotaDenialProvider.notifier);
  denial.state = result;
  final bool subscribed;
  try {
    subscribed = await showPremiumPaywallSheet(context: context);
  } finally {
    if (identical(denial.state, result)) denial.state = null;
  }
  if (!subscribed) return result;
  return repository.check(kind, additions: additions);
}
