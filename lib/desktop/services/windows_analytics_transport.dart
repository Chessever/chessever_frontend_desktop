import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'package:chessever/repository/sqlite/app_database.dart';

/// Best-effort, bounded Windows event delivery. Google credentials live only
/// in the relay. macOS continues to use the native Firebase Analytics SDK.
class WindowsAnalyticsTransport with WidgetsBindingObserver {
  WindowsAnalyticsTransport({
    http.Client? client,
    Future<String?> Function()? readClientId,
    Future<void> Function(String)? saveClientId,
    DateTime Function()? now,
    this.enabled = !kDebugMode,
  }) : _createClient = (() => client ?? http.Client()),
       _readClientId =
           readClientId ?? (() => AppDatabase.instance.getString(_clientIdKey)),
       _saveClientId =
           saveClientId ??
           ((value) => AppDatabase.instance.setString(_clientIdKey, value)),
       _now = now ?? DateTime.now;

  static final Uri endpoint = Uri.parse(
    'https://chessever-windows-analytics.young-sun-69a8.workers.dev/v1/events',
  );
  static const _clientIdKey = 'analytics.windows.client_id.v1';
  static const _sessionTimeout = Duration(minutes: 30);
  static const _maxQueueLength = 100;
  static const _parameterNames = {
    'app_version',
    'build_number',
    'locale',
    'build_mode',
    'screen_name',
    'previous_screen',
    'action',
    'method',
    'success',
    'is_anonymous',
    'tab_kind',
    'closable',
    'surface',
    'outcome',
    'reason',
    'feature',
    'origin',
    'quota',
    'quota_used',
    'quota_limit',
    'interval',
    'stage',
    'source',
    'time_control',
    'month',
    'year',
    'count',
    'is_favorite',
  };
  static final _safeValue = RegExp(r'^[a-zA-Z0-9 _.:+\-]{1,100}$');

  final bool enabled;
  final http.Client Function() _createClient;
  http.Client? _activeClient;
  final Future<String?> Function() _readClientId;
  final Future<void> Function(String) _saveClientId;
  final DateTime Function() _now;
  final List<Map<String, Object>> _pending = [];
  String? _clientId;
  int _sessionId = 0;
  DateTime? _backgroundedAt;
  DateTime? _lastEngagement;
  DateTime? _retryAfter;
  Timer? _flushTimer;
  Timer? _engagementTimer;
  bool _foreground = true;
  bool _observing = false;
  bool _disposed = false;
  Future<void>? _initialization;
  Future<void>? _flushFuture;
  int _failures = 0;

  Future<void> initialize({bool observeLifecycle = true}) =>
      _initialization ??= _initialize(observeLifecycle);

  Future<void> _initialize(bool observeLifecycle) async {
    if (!enabled) return;
    try {
      final saved = await _readClientId();
      if (saved != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(saved)) {
        _clientId = saved;
      } else {
        final random = Random.secure();
        final id =
            List.generate(
              16,
              (_) => random.nextInt(256),
            ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        await _saveClientId(id);
        _clientId = id;
      }
      _sessionId = _now().millisecondsSinceEpoch ~/ 1000;
      _lastEngagement = _now();
      if (observeLifecycle && !_disposed) {
        final binding = WidgetsBinding.instance;
        _foreground =
            binding.lifecycleState == null ||
            binding.lifecycleState == AppLifecycleState.resumed;
        binding.addObserver(this);
        _observing = true;
        _flushTimer = Timer.periodic(const Duration(seconds: 10), (_) {
          unawaited(flush());
        });
        _engagementTimer = Timer.periodic(const Duration(minutes: 1), (_) {
          if (_foreground) addEvent('desktop_engagement', const {});
        });
      }
    } catch (_) {
      // Persistence failures must not prevent the desktop shell from opening.
      debugPrint('[Analytics] Windows analytics initialization failed');
    }
  }

  /// The allowlist deliberately excludes user IDs/properties, email, names,
  /// URLs, file paths, free-text searches and exception details.
  void addEvent(String name, Map<String, Object> properties) {
    if (!enabled || _clientId == null || _disposed) return;
    final now = _now();
    final elapsed =
        _lastEngagement == null || !_foreground
            ? 0
            : now.difference(_lastEngagement!).inMilliseconds.clamp(0, 3600000);
    _lastEngagement = now;
    final params = <String, Object>{
      'session_id': _sessionId,
      'engagement_time_msec': elapsed,
      'platform': 'windows',
    };
    for (final entry in properties.entries) {
      if (!_parameterNames.contains(entry.key)) continue;
      final value = entry.value;
      if (value is num && value.isFinite ||
          value is String && _safeValue.hasMatch(value)) {
        params[entry.key] = value;
      }
      if (params.length >= 25) break;
    }
    if (_pending.length >= _maxQueueLength) _pending.removeAt(0);
    _pending.add({'name': name, 'params': params});
    if (_pending.length >= 25) unawaited(flush());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    final now = _now();
    if (!foreground) {
      // Record the final foreground interval before changing the state.
      addEvent('desktop_engagement', const {});
      _backgroundedAt = now;
      unawaited(flush());
    } else {
      if (_backgroundedAt != null &&
          now.difference(_backgroundedAt!) >= _sessionTimeout) {
        _sessionId = now.millisecondsSinceEpoch ~/ 1000;
      }
      _lastEngagement = now;
    }
    _foreground = foreground;
  }

  Future<void> flush() {
    final active = _flushFuture;
    if (active != null) return active;
    if (_disposed ||
        _pending.isEmpty ||
        _clientId == null ||
        (_retryAfter != null && _now().isBefore(_retryAfter!))) {
      return Future.value();
    }
    return _flushFuture ??= _sendBatch().whenComplete(
      () => _flushFuture = null,
    );
  }

  Future<void> _sendBatch() async {
    final batch = _pending.take(25).toList();
    _pending.removeRange(0, batch.length);
    bool retry = false;
    final client = _createClient();
    _activeClient = client;
    try {
      final response = await client
          .post(
            endpoint,
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'client_id': _clientId, 'events': batch}),
          )
          .timeout(const Duration(seconds: 7));
      retry = response.statusCode == 429 || response.statusCode >= 500;
      if (response.statusCode != 204) {
        debugPrint('[Analytics] Windows relay returned ${response.statusCode}');
      }
    } catch (_) {
      retry = true;
      debugPrint('[Analytics] Windows relay unavailable');
    } finally {
      // Closing the per-batch client also aborts an HTTP request whose Future
      // timed out, so offline telemetry cannot accumulate open connections.
      client.close();
      _activeClient = null;
    }
    if (retry && !_disposed) {
      _failures++;
      if (_failures <= 3) {
        _pending.insertAll(0, batch);
        if (_pending.length > _maxQueueLength) {
          _pending.removeRange(_maxQueueLength, _pending.length);
        }
        _retryAfter = _now().add(Duration(seconds: 10 * (1 << _failures)));
      } else {
        _failures = 0;
        _retryAfter = _now().add(const Duration(minutes: 1));
      }
    } else {
      _failures = 0;
      _retryAfter = null;
    }
  }

  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _engagementTimer?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _pending.clear();
    _activeClient?.close();
  }
}
