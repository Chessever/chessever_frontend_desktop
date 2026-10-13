import 'dart:async';
import 'dart:convert';

import 'package:chessever/repository/local_storage/local_storage_repository.dart';
import 'package:chessever/desktop/services/editorial/discovery_dot.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Remote Config key holding the published dots, edited from the admin
/// console (Nudges). The value is `{"dots":[...]}`; see [parseDiscoveryDots].
const discoveryDotsConfigKey = 'discovery_dots';

abstract interface class DiscoveryDotsSource {
  /// Last activated value, available without a network round trip.
  Future<String> initialize();
  Future<String> fetch();
  Stream<String> get updates;
}

class DesktopDiscoveryDotsSource implements DiscoveryDotsSource {
  DesktopDiscoveryDotsSource({http.Client? client}) : _client = client;
  final http.Client? _client;
  static const cacheKey = 'desktop_discovery_dots.config.v1';
  @override
  Future<String> initialize() async {
    final prefs = await SharedPreferencesService.instance.ensureInitialized();
    return prefs?.getString(cacheKey) ?? '';
  }

  @override
  Future<String> fetch() async {
    Future<http.Response> get(String host) =>
        (_client?.get(Uri.https(host, '/api/nudges')) ??
                http.get(Uri.https(host, '/api/nudges')))
            .timeout(const Duration(seconds: 15));
    var response = await get('chessever.com');
    // The content feed is public. Its production Worker origin keeps native
    // clients working when the website's bot challenge requires a browser.
    if (response.statusCode == 403) {
      response = await get('chessever-web.young-sun-69a8.workers.dev');
    }
    if (response.statusCode != 200) {
      throw StateError('Nudge refresh unavailable');
    }
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic> || value['dots'] is! List) {
      throw const FormatException('Invalid Nudges');
    }
    final prefs = await SharedPreferencesService.instance.ensureInitialized();
    await prefs?.setString(cacheKey, response.body);
    return response.body;
  }

  @override
  Stream<String> get updates => const Stream.empty();
}

/// Device-local memory of which dots were tapped, and at which revision.
class DiscoveryDotsSeenStore {
  const DiscoveryDotsSeenStore();

  static const _key = 'discovery_dots_seen.v1';

  /// Read synchronously from the preferences loaded at startup, so a dismissed
  /// dot never paints for a frame on the next launch.
  Map<String, int> read() {
    final raw = SharedPreferencesService.instance.prefsOrNull?.getString(_key);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is int) entry.key: entry.value as int,
      };
    } on FormatException {
      return const {};
    }
  }

  Future<void> write(Map<String, int> seen) async {
    try {
      final prefs = await SharedPreferencesService.instance.ensureInitialized();
      await prefs?.setString(_key, jsonEncode(seen));
    } catch (e) {
      debugPrint('[DiscoveryDots] dismissal not saved: $e');
    }
  }
}

final discoveryDotsSourceProvider = Provider<DiscoveryDotsSource>(
  (ref) => DesktopDiscoveryDotsSource(),
);

final discoveryDotsSeenStoreProvider = Provider<DiscoveryDotsSeenStore>(
  (ref) => const DiscoveryDotsSeenStore(),
);

class DiscoveryDotsState {
  const DiscoveryDotsState({this.dots = const [], this.seen = const {}})
    : _lit = null;

  DiscoveryDotsState._(this.dots, this.seen)
    : _lit = litDiscoveryAnchors(dots, seen);

  final List<DiscoveryDot> dots;
  final Map<String, int> seen;
  final Set<String>? _lit;

  /// Anchor ids that currently show a dot.
  Set<String> get lit => _lit ?? const {};
}

/// The dots published from the admin console, minus the ones this device has
/// already tapped. Empty until Firebase supplies a value, and empty forever if
/// it never does, so the feature costs nothing when nothing is published.
final discoveryDotsProvider =
    NotifierProvider<DiscoveryDotsNotifier, DiscoveryDotsState>(
      DiscoveryDotsNotifier.new,
    );

class DiscoveryDotsNotifier extends Notifier<DiscoveryDotsState> {
  StreamSubscription<String>? _updates;
  bool _disposed = false;
  DiscoveryDotsSource? _source;
  Future<void>? _refreshing;

  @override
  DiscoveryDotsState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      unawaited(_updates?.cancel());
    });
    final observer = _NudgeResumeObserver(this);
    WidgetsBinding.instance.addObserver(observer);
    final timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(refresh());
      }
    });
    ref.onDispose(() {
      timer.cancel();
      WidgetsBinding.instance.removeObserver(observer);
    });
    unawaited(_load(ref.watch(discoveryDotsSourceProvider)));
    return DiscoveryDotsState(
      seen: ref.watch(discoveryDotsSeenStoreProvider).read(),
    );
  }

  void _apply(String raw) {
    if (_disposed) return;
    state = DiscoveryDotsState._(parseDiscoveryDots(raw), state.seen);
  }

  Future<void> _load(DiscoveryDotsSource source) async {
    _source = source;
    try {
      final cached = await source.initialize();
      if (_disposed) return;
      _apply(cached);
      _updates = source.updates.listen(
        _apply,
        onError: (Object _) {
          debugPrint('[DiscoveryDots] Remote Config update unavailable.');
        },
      );
      try {
        _apply(await source.fetch());
      } catch (_) {
        // Keep the last activated dots on network failure.
        debugPrint('[DiscoveryDots] Remote Config fetch unavailable.');
      }
    } catch (_) {
      debugPrint('[DiscoveryDots] Remote Config unavailable; no dots shown.');
    }
  }

  Future<void> refresh() =>
      _refreshing ??= _fetchLatest().whenComplete(() => _refreshing = null);
  Future<void> _fetchLatest() async {
    if (_source == null || _disposed) return;
    try {
      _apply(await _source!.fetch());
    } catch (_) {
      /* Keep the last confirmed snapshot while offline. */
    }
  }

  /// Records that the user reached [anchor]. Returns the tooltip stack for
  /// every campaign completed at this target, in publication order.
  List<DiscoveryNudgeMessage> acknowledge(String anchor) {
    if (!state.lit.contains(anchor)) return const [];
    final result = acknowledgeDiscoveryAnchor(state.dots, anchor, state.seen);
    state = DiscoveryDotsState._(state.dots, result.seen);
    unawaited(ref.read(discoveryDotsSeenStoreProvider).write(result.seen));
    return result.messages;
  }
}

class _NudgeResumeObserver extends WidgetsBindingObserver {
  _NudgeResumeObserver(this.notifier);
  final DiscoveryDotsNotifier notifier;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(notifier.refresh());
  }
}
