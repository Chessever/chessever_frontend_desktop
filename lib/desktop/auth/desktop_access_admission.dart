/// Container-level admission helpers over [evaluateDesktopAccess].
///
/// The evaluator is pure. These helpers read the live membership out of a
/// Riverpod container (or `Ref`), and route explicit-action denials to the
/// paywall presenter the window registered. Nothing in here imports widgets,
/// so state, services and repositories can admit work without a
/// `BuildContext`.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show AppLifecycleState, VoidCallback;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// Signature shared by `ProviderContainer.read`, `Ref.read` and
/// `WidgetRef.read` tear-offs.
typedef DesktopProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Evaluates [context] against the live membership [read] can see.
///
/// Content that is free for a signed-out guest with no membership is decided
/// without touching the membership at all, so a free broadcast board or an
/// opening position never depends on (or rebuilds with) an entitlement poll.
DesktopAccessDecision readDesktopAccess(
  DesktopProviderRead read,
  DesktopAccessContext context, {
  DateTime? now,
}) {
  final withoutMembership = desktopAccessWithoutMembership(context, now: now);
  if (withoutMembership.isAllowed) return withoutMembership;
  return evaluateDesktopAccess(
    context: context,
    subscription: read(subscriptionProvider),
    entitlement: read(desktopEntitlementProvider),
    now: now,
  );
}

/// The decision for [context] as a guest with no membership. Allowed here
/// means allowed for everyone; anything else must be read against the live
/// membership.
DesktopAccessDecision desktopAccessWithoutMembership(
  DesktopAccessContext context, {
  DateTime? now,
}) => evaluateDesktopAccess(
  context: context,
  subscription: SubscriptionState(),
  entitlement: DesktopEntitlementSnapshot.guest,
  now: now,
);

/// The original action a gate interrupted, resumed ONCE after a verified
/// purchase.
class DesktopAccessResume {
  const DesktopAccessResume({required this.run, this.stillMatches});

  /// Replays the action. Must re-run its own admission (it will pass).
  final FutureOr<void> Function() run;

  /// Whether the document/selection the action targeted is still the one on
  /// screen (same tab, same game, same draft). Null means "no document
  /// binding": only the account check applies.
  final bool Function()? stillMatches;
}

/// Presents a decision to the user in the window that owns the container.
///
/// Resolves to `true` only when a re-read of the live membership admits
/// [context] (or, without a context, Premium is verified active), never on
/// the dialog's own say-so.
typedef DesktopPaywallPresenter =
    Future<bool> Function(
      DesktopAccessDecision decision, {
      DesktopAccessContext? context,
      DesktopAccessResume? resume,
      required String surface,
    });

final Map<ProviderContainer, DesktopPaywallPresenter> _presenters = {};

/// Registers the paywall presenter for a window's container. The window root
/// calls this once; the returned callback unregisters it.
VoidCallback registerDesktopPaywallPresenter(
  ProviderContainer container,
  DesktopPaywallPresenter presenter,
) {
  _presenters[container] = presenter;
  return () {
    if (identical(_presenters[container], presenter)) {
      _presenters.remove(container);
    }
  };
}

/// Test seam: whether the host window is in the foreground. Defaults to the
/// app lifecycle (`resumed`). A background window, a hidden window or a
/// detached window that never received a click must not present a paywall.
bool Function() desktopWindowIsForeground = _lifecycleIsForeground;

bool _lifecycleIsForeground() {
  final state = SchedulerBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
}

/// Presents [decision] through the container's registered presenter, if the
/// window is in the foreground. Returns `false` when nothing could be shown.
///
/// Call only from an explicit user action. Rendering a locked surface, a
/// timer, a stream or a background prefetch must never call this.
Future<bool> presentDesktopAccessDecision(
  ProviderContainer container,
  DesktopAccessDecision decision, {
  DesktopAccessContext? context,
  DesktopAccessResume? resume,
  required String surface,
}) {
  if (decision.isAllowed) return Future<bool>.value(true);
  if (decision.isStale) return Future<bool>.value(false);
  final presenter = _presenters[container];
  if (presenter == null || !desktopWindowIsForeground()) {
    return Future<bool>.value(false);
  }
  return presenter(
    decision,
    context: context,
    resume: resume,
    surface: surface,
  );
}

/// Synchronous admission for an explicit user action.
///
/// Returns `true` when [context] is allowed right now. Otherwise, when
/// [interactive], asks the window to present the decision (fire and forget)
/// and returns `false`: the caller must not start the work. A presented gate
/// replays [resume] once after a verified purchase.
bool admitDesktopAction(
  ProviderContainer container,
  DesktopAccessContext context, {
  required String surface,
  bool interactive = true,
  DesktopAccessResume? resume,
}) {
  final decision = readDesktopAccess(container.read, context);
  if (decision.isAllowed) return true;
  if (interactive) {
    unawaited(
      presentDesktopAccessDecision(
        container,
        decision,
        context: context,
        resume: resume,
        surface: surface,
      ),
    );
  }
  return false;
}

/// Asynchronous admission: allowed now, or allowed after the user completes
/// the presented flow (sign in, purchase, retry) AND a re-read confirms it.
Future<bool> requireDesktopAction(
  ProviderContainer container,
  DesktopAccessContext context, {
  required String surface,
}) async {
  final decision = readDesktopAccess(container.read, context);
  if (decision.isAllowed) return true;
  await presentDesktopAccessDecision(
    container,
    decision,
    context: context,
    surface: surface,
  );
  return readDesktopAccess(container.read, context).isAllowed;
}
