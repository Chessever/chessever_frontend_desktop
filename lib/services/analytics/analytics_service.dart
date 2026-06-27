import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../repository/authentication/model/app_user.dart';
import 'package:chessever/services/appsflyer_service.dart';

/// Centralized analytics facade to keep event names/metadata consistent.
class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();
  static const Set<String> _firebaseUserPropertyDenylist = {
    'email',
    'display_name',
  };

  bool _isReady = false;
  Future<void>? _initFuture;
  Map<String, dynamic> _baseEventProperties = {};
  Map<String, dynamic> _userProperties = {};
  String? _userId;
  FirebaseAnalytics? _firebaseAnalytics;

  final AnalyticsRouteObserver routeObserver = AnalyticsRouteObserver();

  Future<void> initialize() {
    _initFuture ??= _initialize();
    return _initFuture!;
  }

  bool get isReady => _isReady;

  Future<void> _initialize() async {
    _baseEventProperties = await _buildBaseEventProperties();
    _firebaseAnalytics = _createFirebaseAnalytics();
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
      await _firebaseAnalytics?.setUserId(id: null);
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
    await _firebaseAnalytics?.setUserId(id: user.id);
    await _setFirebaseUserProperties(properties);
  }

  Future<void> clearUser() async {
    await _initFuture;
    _userId = null;
    _userProperties = {};
    await _firebaseAnalytics?.setUserId(id: null);
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
    await _setFirebaseUserProperties(normalized);
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
      await _setFirebaseUserProperties(normalizedUserProps);
    }

    await _logFirebaseEvent(eventName, eventProps);

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

  FirebaseAnalytics? _createFirebaseAnalytics() {
    if (Firebase.apps.isEmpty || !_isFirebaseAnalyticsSupported) {
      return null;
    }

    try {
      return FirebaseAnalytics.instance;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Analytics] Firebase Analytics unavailable: $e');
        debugPrintStack(stackTrace: st);
      }
      return null;
    }
  }

  bool get _isFirebaseAnalyticsSupported {
    if (kIsWeb) return true;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  Future<void> _logFirebaseEvent(
    String eventName,
    Map<String, dynamic> properties,
  ) async {
    final analytics = _firebaseAnalytics;
    if (analytics == null) return;

    try {
      await analytics.logEvent(
        name: _toFirebaseName(eventName),
        parameters: _toFirebaseParameters(properties),
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Analytics] Failed to send Firebase event $eventName: $e');
        debugPrintStack(stackTrace: st);
      }
    }
  }

  Future<void> _setFirebaseUserProperties(
    Map<String, dynamic> properties,
  ) async {
    final analytics = _firebaseAnalytics;
    if (analytics == null) return;

    for (final entry in properties.entries) {
      final propertyName = _toFirebaseName(entry.key, maxLength: 24);
      if (_firebaseUserPropertyDenylist.contains(propertyName)) continue;

      final value = _firebaseUserPropertyValue(entry.value);
      if (value == null) continue;
      try {
        await analytics.setUserProperty(name: propertyName, value: value);
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            '[Analytics] Failed to set Firebase user property ${entry.key}: $e',
          );
          debugPrintStack(stackTrace: st);
        }
      }
    }
  }

  Map<String, Object> _toFirebaseParameters(Map<String, dynamic> properties) {
    final parameters = <String, Object>{};
    properties.forEach((key, value) {
      final normalizedValue = _firebaseParameterValue(value);
      if (normalizedValue != null) {
        parameters[_toFirebaseName(key)] = normalizedValue;
      }
    });
    return parameters;
  }

  Object? _firebaseParameterValue(dynamic value) {
    if (value is String) return value;
    if (value is int) return value;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is bool) return value ? 'true' : 'false';
    if (value is DateTime) return value.toIso8601String();
    if (value is Enum) return value.name;
    if (value is Map || value is Iterable) return jsonEncode(value);
    return value?.toString();
  }

  String? _firebaseUserPropertyValue(dynamic value) {
    final normalized = _firebaseParameterValue(value);
    if (normalized == null) return null;
    final stringValue = normalized.toString().trim();
    return stringValue.isEmpty ? null : stringValue;
  }

  String _toFirebaseName(String value, {int maxLength = 40}) {
    final snake = _toSnakeCase(value).replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    final safeName =
        snake.isEmpty || !RegExp(r'^[a-zA-Z]').hasMatch(snake)
            ? 'event_$snake'
            : snake;
    return safeName.length <= maxLength
        ? safeName
        : safeName.substring(0, maxLength);
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
