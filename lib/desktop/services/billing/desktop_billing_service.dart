import 'dart:async';
import 'dart:convert';

import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:flutter/foundation.dart' show debugPrint, immutable, kDebugMode;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Desktop billing entry point.
///
/// Talks to the Supabase Edge Functions:
///   - `/functions/v1/stripe-checkout`  — creates a Stripe Checkout Session
///                                        for a (tier, interval) pair and
///                                        returns the redirect URL.
///   - `/functions/v1/stripe-portal`    — issues a Stripe Customer Portal
///                                        session URL.
///   - `/functions/v1/entitlement`      — returns the user's premium status,
///                                        backed by public.subscriptions.
///
/// All three require the user's Supabase access token in `Authorization:
/// Bearer …`. Override the base URL with
/// `--dart-define=BILLING_API_BASE=https://…/functions/v1` if you ever need
/// to point at a fork or a local supabase functions serve.
class DesktopBillingService {
  DesktopBillingService._();
  static final DesktopBillingService instance = DesktopBillingService._();

  /// Edge Functions base URL, resolved at runtime so no backend project ref
  /// is baked into this (public) client source. Prefers an explicit
  /// `BILLING_API_BASE` override; otherwise derives `<SUPABASE_URL>/functions/v1`
  /// from the same `SUPABASE_URL` the rest of the app already requires.
  static String get _baseUrl {
    final override = DesktopEnv.maybeGet('BILLING_API_BASE');
    if (override != null && override.isNotEmpty) {
      return override.replaceFirst(RegExp(r'/+$'), '');
    }
    final supabaseUrl = DesktopEnv.require('SUPABASE_URL');
    return '${supabaseUrl.replaceFirst(RegExp(r'/+$'), '')}/functions/v1';
  }

  /// Polling cadence for the post-Checkout entitlement watch. 4 s is short
  /// enough that a successful purchase reflects within seconds of the
  /// Stripe entitlement update landing, and cheap enough that we won't
  /// drown the backend if a user leaves the window open.
  static const Duration _pollPeriod = Duration(seconds: 4);

  /// Hard cap so the polling loop terminates if the user closes the Stripe
  /// tab without paying. Stripe's webhook + our entitlement update lands
  /// within seconds of payment; 3 minutes covers transient backend lag
  /// while ensuring the UI doesn't hang on a user who walked away. After
  /// timeout the stream closes and the UI reverts to its idle state with
  /// the "I already subscribed — refresh" CTA still available.
  static const Duration _pollTimeout = Duration(minutes: 3);

  /// Open Stripe Checkout for the requested tier in the user's browser.
  /// The success URL is `chessever://billing/success?session_id=…` which
  /// the desktop app catches via [DesktopDeepLinkListener] and translates
  /// into an entitlement refresh.
  ///
  /// Yields [EntitlementSnapshot]s while polling for the post-purchase
  /// flip; the consumer can short-circuit by listening for the deep link
  /// and calling [currentEntitlement] directly. Stream closes on
  /// [_pollTimeout] so a user who walks away from the Stripe tab does not
  /// strand the caller in a permanent "waiting" state.
  Stream<EntitlementSnapshot> startCheckout({
    required int tier,
    required String interval, // 'month' | 'year'
  }) async* {
    final authToken = await openCheckout(tier: tier, interval: interval);
    yield* _pollEntitlement(authToken: authToken);
  }

  /// Variant of [startCheckout] split into two phases for callers that want
  /// to release a "loading" UI state as soon as the browser is launched and
  /// keep entitlement polling running silently in the background.
  ///
  /// Returns the auth token used so the caller can pass it to a follow-up
  /// [_pollEntitlement]/[watchEntitlement] without paying for another
  /// session refresh.
  Future<String> openCheckout({
    required int tier,
    required String interval,
  }) async {
    final session = await _activeSession(forceRefresh: true);
    if (session == null) {
      throw StateError('Sign in before purchasing.');
    }

    final url = await _createCheckoutUrl(
      authToken: session.accessToken,
      tier: tier,
      interval: interval,
    );

    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      throw StateError('Could not open browser for Stripe Checkout.');
    }
    return session.accessToken;
  }

  /// Bounded entitlement poll using a known auth token, for callers that
  /// already paid for an [openCheckout] round trip.
  Stream<EntitlementSnapshot> pollAfterCheckout(String authToken) =>
      _pollEntitlement(authToken: authToken);

  /// Poll the entitlement endpoint for up to [_pollTimeout] without
  /// creating a Stripe Checkout Session. Used when the user opened the
  /// marketing site / pricing page in their browser (no session id round
  /// trip) and we still want to flip the UI the moment a purchase lands.
  /// Closes naturally on timeout so callers can use stream lifecycle to
  /// drive UI state.
  Stream<EntitlementSnapshot> watchEntitlement() async* {
    final session = await _activeSession(forceRefresh: true);
    if (session == null) return;
    yield* _pollEntitlement(authToken: session.accessToken);
  }

  /// Open the Stripe Customer Portal for the signed-in user.
  Future<bool> openCustomerPortal() async {
    final session = await _activeSession(forceRefresh: true);
    if (session == null) {
      throw StateError('Sign in to manage your subscription.');
    }
    final url = await _createPortalUrl(authToken: session.accessToken);
    return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Returns the user's current entitlement snapshot once. Used by the
  /// subscription notifier to drive [subscriptionProvider] state.
  Future<EntitlementSnapshot?> currentEntitlement({
    bool forceSessionRefresh = false,
  }) async {
    var session = await _activeSession(forceRefresh: forceSessionRefresh);
    if (session == null) return null;

    try {
      return await _fetchEntitlement(authToken: session.accessToken);
    } on DesktopBillingAuthException {
      if (forceSessionRefresh) rethrow;
      session = await _activeSession(forceRefresh: true);
      if (session == null) return null;
      return _fetchEntitlement(authToken: session.accessToken);
    }
  }

  Future<Session?> _activeSession({required bool forceRefresh}) async {
    final auth = Supabase.instance.client.auth;
    var session = auth.currentSession;
    if (session == null) return null;

    if (forceRefresh || session.isExpired) {
      final refreshed = await auth.refreshSession();
      session = refreshed.session ?? auth.currentSession;
    }

    return session;
  }

  Future<String> _createCheckoutUrl({
    required String authToken,
    required int tier,
    required String interval,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/stripe-checkout'),
      headers: <String, String>{
        'authorization': 'Bearer $authToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'tier': tier,
        'interval': interval,
        'return_to': 'desktop',
      }),
    );
    if (resp.statusCode != 200) {
      throw StateError(
        'stripe-checkout returned ${resp.statusCode}: ${resp.body}',
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = body['url'] as String?;
    if (url == null) throw StateError('checkout response missing url');
    return url;
  }

  Future<String> _createPortalUrl({required String authToken}) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/stripe-portal'),
      headers: <String, String>{
        'authorization': 'Bearer $authToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({'return_to': 'desktop'}),
    );
    if (resp.statusCode != 200) {
      throw StateError(
        'stripe-portal returned ${resp.statusCode}: ${resp.body}',
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = body['url'] as String?;
    if (url == null) throw StateError('portal response missing url');
    return url;
  }

  Stream<EntitlementSnapshot> _pollEntitlement({
    required String authToken,
  }) async* {
    final deadline = DateTime.now().add(_pollTimeout);
    EntitlementSnapshot? lastSeen;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final next = await _fetchEntitlement(authToken: authToken);
        if (next != null && next != lastSeen) {
          lastSeen = next;
          yield next;
          if (next.isActive) return;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[billing] poll error: $e');
      }
      await Future<void>.delayed(_pollPeriod);
    }
  }

  Future<EntitlementSnapshot?> _fetchEntitlement({
    required String authToken,
  }) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/entitlement'),
      headers: <String, String>{'authorization': 'Bearer $authToken'},
    );
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw DesktopBillingAuthException(
        'entitlement returned ${resp.statusCode}: ${resp.body}',
      );
    }
    if (resp.statusCode != 200) {
      throw StateError('entitlement returned ${resp.statusCode}: ${resp.body}');
    }
    return EntitlementSnapshot.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
}

class DesktopBillingAuthException implements Exception {
  const DesktopBillingAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

@immutable
class EntitlementSnapshot {
  const EntitlementSnapshot({
    required this.isActive,
    this.tier,
    this.provider,
    this.expiresAt,
    this.willRenew = false,
    this.productId = '',
  });

  /// True if the user has any active "pro" entitlement, regardless of plan.
  /// The Settings UI uses this to gate paywalled features.
  final bool isActive;

  /// 1, 2, or 3 (Stripe web prices). Null for RC mobile entries.
  final int? tier;

  /// 'stripe' | 'revenuecat' | 'apple' | 'google' | null.
  final String? provider;

  /// When the current term ends. `null` for one-time purchases or unknown.
  final DateTime? expiresAt;

  /// Whether the subscription will auto-renew at [expiresAt]. False when the
  /// user has cancelled but the term has not lapsed yet.
  final bool willRenew;

  /// Stripe product id of the active plan, or empty when not subscribed.
  final String productId;

  factory EntitlementSnapshot.fromJson(Map<String, dynamic> json) {
    final cancelAt = switch (json['cancel_at']) {
      String s => DateTime.tryParse(s),
      _ => null,
    };
    return EntitlementSnapshot(
      isActive: json['is_premium'] as bool? ?? false,
      tier: json['tier'] as int?,
      provider: json['provider'] as String?,
      expiresAt: switch (json['expires_at']) {
        String s => DateTime.tryParse(s),
        _ => null,
      },
      willRenew: cancelAt == null,
      productId: json['product_id'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EntitlementSnapshot &&
      isActive == other.isActive &&
      tier == other.tier &&
      provider == other.provider &&
      expiresAt == other.expiresAt &&
      willRenew == other.willRenew &&
      productId == other.productId;

  @override
  int get hashCode =>
      Object.hash(isActive, tier, provider, expiresAt, willRenew, productId);
}
