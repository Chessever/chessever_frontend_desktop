import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../repository/authentication/model/app_user.dart';
import 'package:chessever/services/appsflyer_service.dart';

/// Centralized analytics facade to keep event names/metadata consistent.
class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();

  bool _isReady = false;
  Future<void>? _initFuture;
  Map<String, dynamic> _baseEventProperties = {};
  Map<String, dynamic> _userProperties = {};
  String? _userId;

  final AnalyticsRouteObserver routeObserver = AnalyticsRouteObserver();

  Future<void> initialize() {
    _initFuture ??= _initialize();
    return _initFuture!;
  }

  bool get isReady => _isReady;

  Future<void> _initialize() async {
    _baseEventProperties = await _buildBaseEventProperties();
    _isReady = true;

    trackEventDetached(
      'App Launched',
      properties: {
        'build_mode': kDebugMode ? 'debug' : 'release',
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<void> syncUser(AppUser? user) async {
    await _initFuture;

    _userId = user?.id;
    if (user == null) {
      _userProperties = {};
      return;
    }

    final properties = _normalizeProperties({
      'is_anonymous': user.isAnonymous,
      if (user.email != null && user.email!.isNotEmpty) 'email': user.email,
      if (user.displayName != null && user.displayName!.isNotEmpty)
        'display_name': user.displayName,
      'created_at': user.createdAt.toIso8601String(),
    });

    _userProperties = {..._userProperties, ...properties};
  }

  Future<void> clearUser() async {
    await _initFuture;
    _userId = null;
    _userProperties = {};
  }

  Future<void> trackScreenView({
    required String screenName,
    String? previousScreen,
    Map<String, dynamic>? properties,
  }) {
    return trackEvent(
      'Screen Viewed',
      properties: {
        'screen_name': screenName,
        if (previousScreen != null) 'previous_screen': previousScreen,
        ...?properties,
      },
    );
  }

  Future<void> trackAuthEvent({
    required String action,
    String? method,
    bool? success,
    String? reason,
    AppUser? user,
  }) {
    return trackEvent(
      'Auth Event',
      properties: {
        'action': action,
        if (method != null) 'method': method,
        if (success != null) 'success': success,
        if (reason != null) 'reason': reason,
        'is_anonymous': user?.isAnonymous,
        if (user != null) 'user_id': user.id,
      },
    );
  }

  Future<void> setUserProperties(Map<String, dynamic> properties) async {
    await _initFuture;
    if (properties.isEmpty) return;

    final normalized = _normalizeProperties(properties);
    if (normalized.isEmpty) return;

    _userProperties = {..._userProperties, ...normalized};
  }

  Future<void> trackEvent(
    String eventName, {
    Map<String, dynamic>? properties,
    Map<String, dynamic>? userProperties,
  }) async {
    await _initFuture;
    if (!_isReady) return;

    final eventProps = _normalizeProperties({
      ..._baseEventProperties,
      if (_userId != null) 'user_id': _userId,
      if (properties != null) ...properties,
    });

    final normalizedUserProps =
        userProperties != null ? _normalizeProperties(userProperties) : null;
    if (normalizedUserProps != null && normalizedUserProps.isNotEmpty) {
      _userProperties = {..._userProperties, ...normalizedUserProps};
    }

    try {
      // Also log to AppsFlyer for affiliate marketing tracking.
      await AppsflyerService.instance.logEvent(eventName, eventProps);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Analytics] Failed to send $eventName: $e');
        debugPrintStack(stackTrace: st);
      }
    }
  }

  void trackEventDetached(
    String eventName, {
    Map<String, dynamic>? properties,
    Map<String, dynamic>? userProperties,
  }) {
    unawaited(
      trackEvent(
        eventName,
        properties: properties,
        userProperties: userProperties,
      ),
    );
  }

  Future<Map<String, dynamic>> _buildBaseEventProperties() async {
    String? appVersion;
    String? buildNumber;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = packageInfo.version;
      buildNumber = packageInfo.buildNumber;
    } catch (_) {
      // Safe to ignore; app version is a nice-to-have
    }

    Locale? locale;
    try {
      locale = WidgetsBinding.instance.platformDispatcher.locale;
    } catch (_) {}

    final platformName = kIsWeb ? 'web' : Platform.operatingSystem;
    final osVersion = kIsWeb ? null : Platform.operatingSystemVersion;

    return _normalizeProperties({
      'app_version': appVersion,
      'build_number': buildNumber,
      'platform': platformName,
      'os_version': osVersion,
      'locale': locale?.toLanguageTag(),
      'user_id': _userId,
    });
  }

  Map<String, dynamic> _normalizeProperties(Map<String, dynamic> properties) {
    final normalized = <String, dynamic>{};

    properties.forEach((key, value) {
      if (value == null) return;
      final normalizedKey = _toSnakeCase(key);
      final normalizedValue = _normalizeValue(value);
      if (normalizedValue != null) {
        normalized[normalizedKey] = normalizedValue;
      }
    });

    return normalized;
  }

  dynamic _normalizeValue(dynamic value) {
    if (value is DateTime) return value.toIso8601String();
    if (value is Enum) return value.name;
    if (value is Map<String, dynamic>) return _normalizeProperties(value);
    if (value is Iterable) {
      return value.map(_normalizeValue).whereType<Object>().toList();
    }
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return value;
  }

  String _toSnakeCase(String value) {
    final withUnderscores = value
        .replaceAll(RegExp(r'[\s\-]+'), '_')
        .replaceAllMapped(
          RegExp(r'(?<=[a-z0-9])([A-Z])'),
          (match) => '_${match.group(0)}',
        );
    final collapsed = withUnderscores.replaceAll(RegExp('_+'), '_');
    final trimmed = collapsed.replaceAll(RegExp('^_+|_+\$'), '');
    return trimmed.toLowerCase();
  }
}

class AnalyticsRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  String? _currentScreen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _track(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _track(newRoute, oldRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _track(previousRoute, route);
  }

  void _track(Route<dynamic>? route, Route<dynamic>? previousRoute) {
    final screen = _routeName(route);
    if (screen == null || screen == _currentScreen) return;
    _currentScreen = screen;

    AnalyticsService.instance.trackScreenView(
      screenName: screen,
      previousScreen: _routeName(previousRoute),
    );
  }

  String? _routeName(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null && name.isNotEmpty) return name;
    final runtimeName = route?.runtimeType.toString();
    return runtimeName != null && runtimeName.isNotEmpty ? runtimeName : null;
  }
}
