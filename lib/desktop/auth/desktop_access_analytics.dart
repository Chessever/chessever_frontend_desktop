/// Feature-specific analytics for desktop access gates.
///
/// Properties are limited to the request SHAPE (feature, action, origin,
/// reason code, outcome, quota counts, billing interval, the surface that
/// raised the gate). Never game content, PGN, player names, file paths or
/// chat text.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/services/analytics/analytics_service.dart';

typedef DesktopAccessAnalyticsSink =
    void Function(String event, Map<String, Object?> properties);

class DesktopAccessAnalytics {
  const DesktopAccessAnalytics._();

  static const String gateShownEvent = 'Desktop Access Gate Shown';
  static const String upgradeStartedEvent = 'Desktop Upgrade Started';
  static const String continuationResumedEvent =
      'Desktop Access Continuation Resumed';
  static const String quotaDeniedEvent = 'Desktop Quota Denied';
  static const String operationalErrorEvent = 'Desktop Access Operational Error';

  /// Test seam. When set, events go here instead of [AnalyticsService].
  @visibleForTesting
  static DesktopAccessAnalyticsSink? debugSink;

  /// A paywall, sign-in ask or Retry surface was presented for [decision].
  /// Quota and operational outcomes also emit their specific event.
  static void gateShown(
    DesktopAccessDecision decision, {
    DesktopAccessContext? context,
    required String surface,
  }) {
    final properties = _properties(decision, context, surface);
    _emit(gateShownEvent, properties);
    if (decision.outcome == DesktopAccess.quotaExceeded) {
      _emit(quotaDeniedEvent, properties);
    } else if (decision.outcome == DesktopAccess.temporarilyUnavailable) {
      _emit(operationalErrorEvent, properties);
    }
  }

  static void upgradeStarted(
    DesktopAccessDecision decision, {
    DesktopAccessContext? context,
    required String surface,
    required String interval,
  }) {
    _emit(upgradeStartedEvent, {
      ..._properties(decision, context, surface),
      'interval': interval,
    });
  }

  static void continuationResumed(
    DesktopAccessDecision decision, {
    DesktopAccessContext? context,
    required String surface,
  }) {
    _emit(continuationResumedEvent, _properties(decision, context, surface));
  }

  /// Checkout, pricing or membership refresh failed. [stage] is a fixed
  /// identifier (`checkout_open`, `checkout_poll`, `refresh`), never an
  /// exception message.
  static void operationalError(
    DesktopAccessDecision decision, {
    DesktopAccessContext? context,
    required String surface,
    required String stage,
  }) {
    _emit(operationalErrorEvent, {
      ..._properties(decision, context, surface),
      'stage': stage,
    });
  }

  static Map<String, Object?> _properties(
    DesktopAccessDecision decision,
    DesktopAccessContext? context,
    String surface,
  ) {
    final capacity = decision.capacity;
    return <String, Object?>{
      'surface': surface,
      'outcome': decision.outcome.name,
      'reason': decision.reason.code,
      if (context != null) 'feature': context.feature.name,
      if (context != null) 'action': context.action.name,
      if (context != null) 'origin': context.origin.name,
      if (capacity != null) 'quota': capacity.quota.name,
      if (capacity != null) 'quota_used': capacity.used,
      if (capacity != null) 'quota_limit': capacity.limit,
    };
  }

  static void _emit(String event, Map<String, Object?> properties) {
    final sink = debugSink;
    if (sink != null) {
      sink(event, properties);
      return;
    }
    try {
      AnalyticsService.instance.trackEventDetached(
        event,
        properties: Map<String, dynamic>.of(properties),
      );
    } catch (_) {
      // Analytics must never break an access decision.
    }
  }
}
