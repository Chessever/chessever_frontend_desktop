import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/services/desktop_env.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';

/// Interval the board panel re-reads the organiser-managed stream list.
/// Matches the web's 30-second `VideoStreams` refresh.
const Duration broadcastVideoStreamsRefreshInterval = Duration(seconds: 30);

final broadcastVideoStreamsClientProvider =
    Provider<BroadcastVideoStreamsClient>((ref) {
      // `BROADCAST_API_BASE` is an optional debug/UAT override; production
      // carries the public origin as the client default.
      final override = DesktopEnv.maybeGet('BROADCAST_API_BASE');
      final client = BroadcastVideoStreamsClient(
        baseUrl:
            override == null || override.isEmpty ? null : Uri.parse(override),
      );
      ref.onDispose(client.dispose);
      return client;
    });

/// Per-spectator stream list for one board context. Polls while a panel is
/// mounted, holds popularity snapshots steady across refreshes (so a metadata
/// update cannot reshuffle or swap the current video), and keeps the last
/// good list when a refresh fails. Mirrors `VideoStreams.tsx`.
class BroadcastVideoStreamsNotifier
    extends
        AutoDisposeFamilyAsyncNotifier<
          ResolvedBroadcastVideoStreams,
          BroadcastVideoScope
        > {
  Timer? _timer;

  /// Riverpod 2 keeps this notifier instance across rebuilds (a
  /// `ref.invalidate`, for example) and runs `onDispose` before each one, so
  /// liveness is tracked per build rather than as a one-way flag on the
  /// instance; otherwise the first rebuild would silence polling for good.
  int _generation = 0;
  bool _live = false;
  final Map<String, ({BroadcastVideoAudience? audience, bool? preferred})>
  _snapshots =
      <String, ({BroadcastVideoAudience? audience, bool? preferred})>{};

  @override
  Future<ResolvedBroadcastVideoStreams> build(BroadcastVideoScope arg) async {
    final generation = ++_generation;
    _live = true;
    ref.onDispose(() {
      _live = false;
      _timer?.cancel();
      _timer = null;
    });
    _timer = Timer.periodic(
      broadcastVideoStreamsRefreshInterval,
      (_) => unawaited(_refresh(generation)),
    );
    // Re-read the moment the window returns to the foreground, like the
    // web's `visibilitychange` listener; the periodic tick skips a hidden
    // window (below) so a returning spectator would otherwise wait a cycle.
    ref.listen<bool>(liveGameStreamingLifecycleProvider, (previous, next) {
      if (next && previous == false) unawaited(_refresh(generation));
    });
    return _fetch(arg);
  }

  bool _isCurrent(int generation) => _live && generation == _generation;

  Future<ResolvedBroadcastVideoStreams> _fetch(
    BroadcastVideoScope scope,
  ) async {
    final client = ref.read(broadcastVideoStreamsClientProvider);
    final value = await client.fetch(scope);
    // Hold popularity / manual-priority snapshots for this viewed scope.
    final streams = value.streams
        .map((stream) {
          final key = '${stream.id}:${stream.url}';
          final snapshot = _snapshots.putIfAbsent(
            key,
            () => (audience: stream.audience, preferred: stream.preferred),
          );
          return BroadcastVideoStream(
            id: stream.id,
            label: stream.label,
            countryCode: stream.countryCode,
            provider: stream.provider,
            sourceId: stream.sourceId,
            url: stream.url,
            publication: stream.publication,
            audience: snapshot.audience,
            preferred: snapshot.preferred,
          );
        })
        .toList(growable: false);
    return ResolvedBroadcastVideoStreams(
      streams: streams,
      source: value.source,
    );
  }

  Future<void> _refresh(int generation) async {
    if (!_isCurrent(generation)) return;
    // A background window is not watching; mirror the web's document.hidden
    // pause so we do not poll (or wake radios) for nobody.
    if (!ref.read(liveGameStreamingLifecycleProvider)) return;
    try {
      final next = await _fetch(arg);
      if (!_isCurrent(generation)) return;
      state = AsyncData<ResolvedBroadcastVideoStreams>(next);
    } on BroadcastVideoStreamsException catch (error, stackTrace) {
      if (!_isCurrent(generation)) return;
      // A permanent failure (the scope is gone or the payload is invalid)
      // clears an already playing panel; transient failures keep it.
      if (error.permanent) {
        state = AsyncError<ResolvedBroadcastVideoStreams>(error, stackTrace);
      }
    } catch (_) {
      // Transient failures never interrupt an already playing video.
    }
  }
}

final broadcastVideoStreamsProvider = AsyncNotifierProvider.autoDispose.family<
  BroadcastVideoStreamsNotifier,
  ResolvedBroadcastVideoStreams,
  BroadcastVideoScope
>(BroadcastVideoStreamsNotifier.new);

/// Session-scoped per-tournament preference: which stream, which legacy
/// country fallback, and whether the panel is expanded. Mirrors the web's
/// `sessionStorage` key `ce-video.v1:<tournamentId>`.
class BroadcastVideoPreference {
  const BroadcastVideoPreference({
    this.selectedId,
    this.countryCode,
    this.visible,
  });

  final String? selectedId;
  final String? countryCode;
  final bool? visible;

  BroadcastVideoPreference copyWith({
    String? selectedId,
    String? countryCode,
    bool? visible,
  }) {
    return BroadcastVideoPreference(
      selectedId: selectedId ?? this.selectedId,
      countryCode: countryCode ?? this.countryCode,
      visible: visible ?? this.visible,
    );
  }
}

class BroadcastVideoSessionPreferences
    extends Notifier<Map<String, BroadcastVideoPreference>> {
  @override
  Map<String, BroadcastVideoPreference> build() =>
      <String, BroadcastVideoPreference>{};

  BroadcastVideoPreference read(String storageKey) =>
      state[storageKey] ?? const BroadcastVideoPreference();

  void write(String storageKey, BroadcastVideoPreference preference) {
    state = <String, BroadcastVideoPreference>{
      ...state,
      storageKey: preference,
    };
  }
}

final broadcastVideoSessionPreferencesProvider = NotifierProvider<
  BroadcastVideoSessionPreferences,
  Map<String, BroadcastVideoPreference>
>(BroadcastVideoSessionPreferences.new);

/// Last watched language group, shared across tournaments and persisted like
/// the web's `localStorage` key `ce-video-language.v1`.
class BroadcastVideoLanguageController extends AsyncNotifier<String?> {
  static const String storageKey = 'ce-video-language.v1';

  @override
  Future<String?> build() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final value = preferences.getString(storageKey);
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> remember(String languageGroupKey) async {
    state = AsyncData<String?>(languageGroupKey);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(storageKey, languageGroupKey);
    } catch (_) {
      // Storage is optional; the in-memory value still applies this session.
    }
  }
}

final broadcastVideoLanguageProvider =
    AsyncNotifierProvider<BroadcastVideoLanguageController, String?>(
      BroadcastVideoLanguageController.new,
    );
