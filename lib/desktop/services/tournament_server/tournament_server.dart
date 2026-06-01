import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// Hide dartchess's `File` enum (board files a–h) so dart:io's [File] wins.
import 'package:dartchess/dartchess.dart' hide File;
import 'package:dart_frog/dart_frog.dart' as frog;
import 'package:dart_frog_web_socket/dart_frog_web_socket.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/maia3_engine.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_resource_assessor.dart';

/// Top-level lifecycle for the embedded tournament server. Lives on
/// localhost — we never bind to a public interface, and only one instance
/// can run at a time (enforced via a `.lock` file under app-support).
enum TournamentServerStatus { stopped, starting, running, stopping, error }

@immutable
class TournamentServerState {
  const TournamentServerState({
    required this.status,
    this.port,
    this.error,
    this.snapshot,
  });

  final TournamentServerStatus status;
  final int? port;
  final String? error;

  /// Latest tournament snapshot the server is broadcasting. Null when no
  /// tournament has been created yet.
  final TournamentSnapshot? snapshot;

  TournamentServerState copyWith({
    TournamentServerStatus? status,
    int? port,
    String? error,
    TournamentSnapshot? snapshot,
    bool clearError = false,
    bool clearSnapshot = false,
    bool clearPort = false,
  }) {
    return TournamentServerState(
      status: status ?? this.status,
      port: clearPort ? null : (port ?? this.port),
      error: clearError ? null : (error ?? this.error),
      snapshot: clearSnapshot ? null : (snapshot ?? this.snapshot),
    );
  }
}

/// Local-only tournament conductor.
///
/// Wire diagram:
///   [Server]  HTTP /status   ──  status + latest snapshot
///             WS    /events  ──  durable TournamentSnapshot events
///   [Conductor]                ──  pairing logic, per-game UCI process pool
///   [GameRunner] per game      ──  drives two engines turn-by-turn
///
/// Dart Frog gives us a small Shelf-backed local server with typed routes
/// while staying inside the Flutter process and binding only to loopback.
class TournamentServer extends StateNotifier<TournamentServerState> {
  TournamentServer()
    : super(
        const TournamentServerState(status: TournamentServerStatus.stopped),
      );

  HttpServer? _http;
  File? _lockFile;
  File? _eventLogFile;
  final List<_TournamentSubscriber> _subscribers = [];
  final List<StreamController<List<int>>> _sseSubscribers = [];
  Conductor? _conductor;
  int _eventSeq = 0;
  Future<void> _eventWriteChain = Future<void>.value();

  Future<bool> start() async {
    if (state.status == TournamentServerStatus.running ||
        state.status == TournamentServerStatus.starting) {
      return state.status == TournamentServerStatus.running;
    }
    state = state.copyWith(
      status: TournamentServerStatus.starting,
      clearError: true,
    );
    try {
      await _acquireLock();
      // Bind on 127.0.0.1 only — never expose to the LAN.
      final router =
          frog.Router()
            ..get('/status', _handleStatusRoute)
            ..get('/events', (context) => _handleEventsRoute(context))
            ..get(
              '/events/stream',
              (context) => _handleEventStreamRoute(context),
            );
      final server = await frog.serve(
        (context) => router(context),
        InternetAddress.loopbackIPv4,
        0,
      );
      _http = server;
      state = state.copyWith(
        status: TournamentServerStatus.running,
        port: server.port,
      );
      if (kDebugMode) {
        debugPrint('🏁 Tournament server running on 127.0.0.1:${server.port}');
      }
      return true;
    } catch (e, st) {
      if (kDebugMode) debugPrint('Tournament server start failed: $e\n$st');
      state = state.copyWith(
        status: TournamentServerStatus.error,
        error: e.toString(),
        clearPort: true,
      );
      await _releaseLock();
      return false;
    }
  }

  Future<void> stop() async {
    if (state.status == TournamentServerStatus.stopped ||
        state.status == TournamentServerStatus.stopping) {
      return;
    }
    state = state.copyWith(status: TournamentServerStatus.stopping);
    await _conductor?.shutdown();
    _conductor = null;
    for (final subscriber in _subscribers) {
      try {
        await subscriber.close();
      } catch (_) {}
    }
    _subscribers.clear();
    for (final subscriber in _sseSubscribers) {
      try {
        await subscriber.close();
      } catch (_) {}
    }
    _sseSubscribers.clear();
    try {
      await _eventWriteChain;
    } catch (_) {}
    _eventLogFile = null;
    _eventSeq = 0;
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
    await _releaseLock();
    state = const TournamentServerState(status: TournamentServerStatus.stopped);
  }

  /// Create + run a tournament. Returns immediately; progress is streamed
  /// via [state.snapshot] / `events` WebSocket.
  Future<void> launchTournament(TournamentConfig config) async {
    if (state.status != TournamentServerStatus.running) {
      throw StateError('Server not running — call start() first.');
    }
    await _conductor?.shutdown();
    await _resetEventLog(config.title);
    final conductor = Conductor(
      config: config,
      onSnapshotChange: (s) {
        state = state.copyWith(snapshot: s);
        _publishSnapshot(s);
      },
      enginePathFor: _enginePathForKind,
    );
    _conductor = conductor;
    // ignore: unawaited_futures
    conductor.run();
  }

  Future<void> stopTournamentStream() async {
    await _conductor?.shutdown();
    _conductor = null;
    final snapshot = state.snapshot;
    if (snapshot != null) {
      final stopped = snapshot.copyWith(isRunning: false);
      state = state.copyWith(snapshot: stopped);
      _publishSnapshot(stopped);
    }
  }

  Future<TournamentSnapshot?> abortTournamentStream() async {
    await _conductor?.shutdown();
    _conductor = null;
    final snapshot = state.snapshot;
    if (snapshot == null) return null;
    final aborted = snapshot.copyWith(isRunning: false);
    _publishSnapshot(aborted);
    state = state.copyWith(clearSnapshot: true, clearError: true);
    return aborted;
  }

  Future<void> restartTournamentStream() async {
    final snapshot = state.snapshot;
    if (snapshot == null) return;
    await launchTournament(
      snapshot.config.copyWith(id: newTournamentEventId()),
    );
  }

  Future<void> continueTournamentStream() async {
    final snapshot = state.snapshot;
    if (snapshot == null || snapshot.isRunning) return;
    if (state.status != TournamentServerStatus.running) {
      final ready = await start();
      if (!ready) return;
    }
    await _conductor?.shutdown();
    final conductor = Conductor(
      config: snapshot.config,
      resumeFrom: snapshot,
      onSnapshotChange: (s) {
        state = state.copyWith(snapshot: s);
        _publishSnapshot(s);
      },
      enginePathFor: _enginePathForKind,
    );
    _conductor = conductor;
    unawaited(conductor.run());
  }

  TournamentGame? markHumanGameStarted(String gameId) {
    return _conductor?.markHumanGameStarted(gameId);
  }

  void resetHumanGame(String gameId) {
    _conductor?.resetHumanGame(gameId);
  }

  void recordHumanGameResult({
    required String gameId,
    required String result,
    required String fen,
    required List<String> movesUci,
    required int whiteMillis,
    required int blackMillis,
    required String endReason,
  }) {
    _conductor?.recordHumanGameResult(
      gameId: gameId,
      result: result,
      fen: fen,
      movesUci: movesUci,
      whiteMillis: whiteMillis,
      blackMillis: blackMillis,
      endReason: endReason,
    );
  }

  void recordHumanGameProgress({
    required String gameId,
    required String fen,
    required List<String> movesUci,
    required int whiteMillis,
    required int blackMillis,
  }) {
    _conductor?.recordHumanGameProgress(
      gameId: gameId,
      fen: fen,
      movesUci: movesUci,
      whiteMillis: whiteMillis,
      blackMillis: blackMillis,
    );
  }

  // --- Dart Frog HTTP / WS plumbing ---

  frog.Response _handleStatusRoute(frog.RequestContext context) {
    return frog.Response.json(
      body: {
        'status': state.status.name,
        'port': state.port,
        'eventSeq': _eventSeq,
        'tournament':
            state.snapshot == null ? null : _snapshotToJson(state.snapshot!),
      },
    );
  }

  Future<frog.Response> _handleEventsRoute(frog.RequestContext context) async {
    final since = int.tryParse(
      context.request.uri.queryParameters['since'] ?? '',
    );
    final replay = since == null ? const <String>[] : await _eventsSince(since);
    final currentSnapshot = state.snapshot;
    final handler = webSocketHandler((channel, protocol) {
      final subscriber = _TournamentSubscriber(
        send: (json) => channel.sink.add(json),
        close: () async => channel.sink.close(),
      );
      _subscribers.add(subscriber);
      for (final event in replay) {
        subscriber.send(event);
      }
      if (since == null && currentSnapshot != null) {
        subscriber.send(_ephemeralSnapshotEventJson(currentSnapshot));
      }
      channel.stream.listen(
        (_) {},
        onDone: () => _subscribers.remove(subscriber),
        onError: (_) => _subscribers.remove(subscriber),
      );
    });
    return handler(context);
  }

  Future<frog.Response> _handleEventStreamRoute(
    frog.RequestContext context,
  ) async {
    final since = int.tryParse(
      context.request.uri.queryParameters['since'] ?? '',
    );
    final replay = since == null ? const <String>[] : await _eventsSince(since);
    final currentSnapshot = state.snapshot;
    final controller = StreamController<List<int>>();
    _sseSubscribers.add(controller);
    controller.onCancel = () => _sseSubscribers.remove(controller);

    void send(String json) {
      if (controller.isClosed) return;
      controller.add(utf8.encode('data: $json\n\n'));
    }

    for (final event in replay) {
      send(event);
    }
    if (since == null && currentSnapshot != null) {
      send(_ephemeralSnapshotEventJson(currentSnapshot));
    }

    return frog.Response.stream(
      body: controller.stream,
      headers: {
        HttpHeaders.contentTypeHeader: 'text/event-stream',
        HttpHeaders.cacheControlHeader: 'no-cache',
        HttpHeaders.connectionHeader: 'keep-alive',
      },
    );
  }

  void _broadcast(String json) {
    for (final subscriber in _subscribers) {
      try {
        subscriber.send(json);
      } catch (_) {}
    }
    final bytes = utf8.encode('data: $json\n\n');
    for (final subscriber in List.of(_sseSubscribers)) {
      if (subscriber.isClosed) {
        _sseSubscribers.remove(subscriber);
        continue;
      }
      try {
        subscriber.add(bytes);
      } catch (_) {
        _sseSubscribers.remove(subscriber);
      }
    }
  }

  void _publishSnapshot(TournamentSnapshot snapshot) {
    final encoded = _snapshotEventJson(snapshot);
    _broadcast(encoded);
    final log = _eventLogFile;
    if (log == null) return;
    _eventWriteChain = _eventWriteChain
        .then((_) async {
          await log.writeAsString(
            '$encoded\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (kDebugMode) {
            debugPrint(
              'Tournament event log write failed: $error\n$stackTrace',
            );
          }
        });
  }

  String _snapshotEventJson(TournamentSnapshot snapshot) {
    _eventSeq++;
    return _encodeSnapshotEvent(snapshot, seq: _eventSeq);
  }

  String _ephemeralSnapshotEventJson(TournamentSnapshot snapshot) {
    return _encodeSnapshotEvent(snapshot, seq: _eventSeq);
  }

  String _encodeSnapshotEvent(TournamentSnapshot snapshot, {required int seq}) {
    return jsonEncode({
      'seq': seq,
      'type': 'snapshot',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'snapshot': _snapshotToJson(snapshot),
    });
  }

  Future<void> _resetEventLog(String title) async {
    await _eventWriteChain;
    _eventSeq = 0;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'tournament_server', 'events'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final safeTitle = title
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final log = File(
      p.join(
        dir.path,
        '${DateTime.now().toUtc().millisecondsSinceEpoch}_$safeTitle.jsonl',
      ),
    );
    await log.writeAsString('', flush: true);
    _eventLogFile = log;
  }

  Future<List<String>> _eventsSince(int seq) async {
    final log = _eventLogFile;
    if (log == null || !await log.exists()) return const <String>[];
    await _eventWriteChain;
    final out = <String>[];
    await for (final line in log
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      final eventSeq = decoded['seq'];
      if (eventSeq is int && eventSeq > seq) out.add(line);
    }
    return out;
  }

  // --- single-instance lock ---

  Future<void> _acquireLock() async {
    final support = await getApplicationSupportDirectory();
    final lockDir = Directory(p.join(support.path, 'tournament_server'));
    if (!await lockDir.exists()) await lockDir.create(recursive: true);
    final lock = File(p.join(lockDir.path, 'server.lock'));
    if (await lock.exists()) {
      // Stale-lock detection: read the PID; if the process isn't alive we
      // assume the previous app crashed and reclaim. On the desktop OSes
      // we care about, `kill -0` (POSIX) / a no-op tasklist check
      // (Windows) is the cheapest probe.
      final pidStr = await lock.readAsString();
      final pid = int.tryParse(pidStr.trim());
      if (pid != null && !_isProcessAlive(pid)) {
        await lock.delete();
      } else {
        throw StateError(
          'A tournament server is already running (pid $pidStr). '
          'Only one server can run at a time.',
        );
      }
    }
    await lock.writeAsString(pid.toString());
    _lockFile = lock;
  }

  Future<void> _releaseLock() async {
    final lock = _lockFile;
    _lockFile = null;
    if (lock != null && await lock.exists()) {
      try {
        await lock.delete();
      } catch (_) {}
    }
  }

  bool _isProcessAlive(int otherPid) {
    if (Platform.isWindows) {
      // Synchronous probe avoids racing async lifecycle. Cost is one
      // tasklist invocation per stale-lock check (extremely rare).
      final res = Process.runSync('tasklist', ['/FI', 'PID eq $otherPid']);
      return (res.stdout as String).contains('$otherPid');
    }
    try {
      final res = Process.runSync('kill', ['-0', '$otherPid']);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // --- engine path resolution ---

  String? Function(BotEngineKind kind)? _enginePathForKindOverride;

  /// Overrides the path resolver. Set by the UI layer right after start()
  /// so the conductor can pull binaries from the engineInstallProvider
  /// without the server importing Riverpod.
  void setEnginePathResolver(String? Function(BotEngineKind) resolver) {
    _enginePathForKindOverride = resolver;
  }

  String? _enginePathForKind(BotEngineKind kind) {
    final override = _enginePathForKindOverride;
    if (override != null) return override(kind);
    return null;
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}

class _TournamentSubscriber {
  const _TournamentSubscriber({required this.send, required this.close});

  final void Function(String json) send;
  final Future<void> Function() close;
}

Map<String, dynamic> _snapshotToJson(TournamentSnapshot s) {
  return {
    'id': s.config.id,
    'title': s.config.title,
    'format': s.config.format.name,
    'knockoutTiebreakMode': s.config.knockoutTiebreakMode.name,
    'knockoutReseeding': s.config.knockoutReseeding.name,
    'isRunning': s.isRunning,
    'currentRound': s.currentRound,
    'totalRounds': s.totalRounds,
    'resource': {
      'level': s.resourceAssessment.level.name,
      'hostCores': s.resourceAssessment.hostCores,
      'recommendedConcurrency': s.resourceAssessment.recommendedConcurrency,
      'recommendedMaxParticipants':
          s.resourceAssessment.recommendedMaxParticipants,
      'message': s.resourceAssessment.message,
    },
    'participants': [
      for (final p in s.config.participants)
        {
          'id': p.id,
          'name': p.identity.displayName,
          'fullName': p.identity.fullName,
          'title': p.identity.title,
          'nickname': p.identity.nickname,
          'country': p.identity.countryCode,
          'elo': p.identity.elo,
          'engine': p.engine.name,
          'human': p.isHuman,
        },
    ],
    'standings': [
      for (final st in s.standings)
        {'id': st.participantId, 'points': st.points, 'played': st.played},
    ],
    'games': [
      for (final g in s.games)
        {
          'id': g.id,
          'round': g.round,
          'white': g.whiteId,
          'black': g.blackId,
          'status': g.status.name,
          'result': g.result,
          'fen': g.fen,
          'lastMove': g.lastMoveUci,
          'moves': g.movesUci,
          'whiteMillis': g.whiteMillis,
          'blackMillis': g.blackMillis,
          'endReason': g.endReason,
          'eco': g.ecoLine,
          'baseSecondsOverride': g.baseSecondsOverride,
          'incrementSecondsOverride': g.incrementSecondsOverride,
          'drawAdvancesParticipantId': g.drawAdvancesParticipantId,
          'tiebreakLabel': g.tiebreakLabel,
          'clockUpdatedAt': g.clockUpdatedAt?.toUtc().toIso8601String(),
        },
    ],
  };
}

/// The conductor sits on top of the server. Runs the pairing algorithm,
/// spawns [GameRunner] per active game (concurrency capped to keep CPU low),
/// and updates the snapshot after each move / game-end.
class Conductor {
  Conductor({
    required this.config,
    required this.onSnapshotChange,
    required this.enginePathFor,
    this.resumeFrom,
  });

  final TournamentConfig config;
  final void Function(TournamentSnapshot) onSnapshotChange;
  final String? Function(BotEngineKind) enginePathFor;
  final TournamentSnapshot? resumeFrom;

  late List<TournamentGame> _games;
  late int _currentRound;
  late int _totalRounds;
  bool _stopped = false;
  bool _completed = false;
  late TournamentResourceAssessment _resourceAssessment;

  /// Maximum concurrent games. Keeping it small (4) is the difference
  /// between "feels live" and "fan starts howling": each game runs two
  /// engines spending wall clock thinking, so on a 6-core laptop we end up
  /// at ~80% CPU. Tweak via [setConcurrency] for tournaments on burlier
  /// machines.
  late int _concurrency;
  final List<GameRunner> _running = [];

  int get concurrency => _concurrency;
  void setConcurrency(int value) => _concurrency = value.clamp(1, 8);

  Future<void> run() async {
    _resourceAssessment = assessTournamentConfig(config);
    _concurrency = _resourceAssessment.recommendedConcurrency;
    if (config.format == TournamentFormat.knockout) {
      await _runKnockout();
      return;
    }

    _games = _resumableGames(resumeFrom?.games) ?? _buildSchedule(config);
    _totalRounds = _games.fold<int>(0, (m, g) => g.round > m ? g.round : m);
    _concurrency = max(_concurrency, _maxEngineGamesInAnyRound()).clamp(1, 8);
    _currentRound = _computeCurrentRound();
    _emit();
    while (!_stopped) {
      final nextRound = _computeCurrentRound();
      if (nextRound == 0 || !_hasUnfinishedGames()) break;
      _currentRound = nextRound;
      _emit();
      await _runRoundUntilIdle(nextRound);
    }
    _completed = !_stopped && !_hasUnfinishedGames();
    _currentRound = _completed ? _totalRounds : _computeCurrentRound();
    _emit();
  }

  Future<void> shutdown() async {
    _stopped = true;
    for (final r in _running) {
      await r.cancel();
    }
    _running.clear();
  }

  TournamentGame? markHumanGameStarted(String gameId) {
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index < 0) return null;
    final game = _games[index];
    if (!_isHumanGame(game) || game.status == TournamentGameStatus.finished) {
      return game;
    }
    if (game.status == TournamentGameStatus.inProgress) {
      return game;
    }
    final baseSeconds = game.baseSecondsOverride ?? config.baseSeconds;
    final startingFen = _ecoSeedForRound(game.round)?.fen ?? Chess.initial.fen;
    final now = DateTime.now();
    final inProgress = game.copyWith(
      status: TournamentGameStatus.inProgress,
      result: '*',
      whiteMillis: baseSeconds * 1000,
      blackMillis: baseSeconds * 1000,
      startingFen: startingFen,
      fen: startingFen,
      ecoLine: _ecoSeedForRound(game.round)?.label,
      clockUpdatedAt: now,
    );
    _replaceGame(inProgress);
    _emit();
    return inProgress;
  }

  void resetHumanGame(String gameId) {
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index < 0) return;
    final game = _games[index];
    if (!_isHumanGame(game)) return;
    _replaceGame(
      TournamentGame(
        id: game.id,
        round: game.round,
        whiteId: game.whiteId,
        blackId: game.blackId,
        status: TournamentGameStatus.scheduled,
        baseSecondsOverride: game.baseSecondsOverride,
        incrementSecondsOverride: game.incrementSecondsOverride,
        drawAdvancesParticipantId: game.drawAdvancesParticipantId,
        tiebreakLabel: game.tiebreakLabel,
      ),
    );
    _emit();
  }

  void recordHumanGameResult({
    required String gameId,
    required String result,
    required String fen,
    required List<String> movesUci,
    required int whiteMillis,
    required int blackMillis,
    required String endReason,
  }) {
    final game = _gameById(gameId);
    if (game == null || !_isHumanGame(game)) return;
    _replaceGame(
      game.copyWith(
        status: TournamentGameStatus.finished,
        result: result,
        fen: fen,
        lastMoveUci: movesUci.isEmpty ? null : movesUci.last,
        movesUci: movesUci,
        whiteMillis: whiteMillis,
        blackMillis: blackMillis,
        endReason: endReason,
        clockUpdatedAt: DateTime.now(),
      ),
    );
    _currentRound = _computeCurrentRound();
    _emit();
  }

  void recordHumanGameProgress({
    required String gameId,
    required String fen,
    required List<String> movesUci,
    required int whiteMillis,
    required int blackMillis,
  }) {
    final game = _gameById(gameId);
    if (game == null ||
        !_isHumanGame(game) ||
        game.status == TournamentGameStatus.finished) {
      return;
    }
    _replaceGame(
      game.copyWith(
        status: TournamentGameStatus.inProgress,
        result: '*',
        fen: fen,
        lastMoveUci: movesUci.isEmpty ? null : movesUci.last,
        movesUci: movesUci,
        whiteMillis: whiteMillis,
        blackMillis: blackMillis,
        clockUpdatedAt: DateTime.now(),
      ),
    );
    _currentRound = _computeCurrentRound();
    _emit();
  }

  TournamentGame? _nextScheduled({int? round}) {
    for (final g in _games) {
      if (round != null && g.round != round) continue;
      if (_isHumanGame(g)) continue;
      if (g.status == TournamentGameStatus.scheduled) return g;
    }
    return null;
  }

  bool _hasUnfinishedGames({int? round}) {
    for (final g in _games) {
      if (round != null && g.round != round) continue;
      if (g.status != TournamentGameStatus.finished) return true;
    }
    return false;
  }

  bool _isHumanGame(TournamentGame game) {
    return _participantById(game.whiteId)?.isHuman == true ||
        _participantById(game.blackId)?.isHuman == true;
  }

  TournamentGame? _gameById(String id) {
    for (final game in _games) {
      if (game.id == id) return game;
    }
    return null;
  }

  void _replaceGame(TournamentGame updated) {
    _games = [
      for (final old in _games)
        if (old.id == updated.id) updated else old,
    ];
  }

  void _pruneFinished() {
    _running.removeWhere((r) => r.finished);
  }

  void _startGame(TournamentGame g) {
    final baseSeconds = g.baseSecondsOverride ?? config.baseSeconds;
    final incrementSeconds =
        g.incrementSecondsOverride ?? config.incrementSeconds;
    final now = DateTime.now();
    final inProgress = g.copyWith(
      status: TournamentGameStatus.inProgress,
      result: '*',
      whiteMillis: baseSeconds * 1000,
      blackMillis: baseSeconds * 1000,
      startingFen: _ecoSeedForRound(g.round)?.fen ?? Chess.initial.fen,
      ecoLine: _ecoSeedForRound(g.round)?.label,
      clockUpdatedAt: now,
    );
    _games = [
      for (final old in _games)
        if (old.id == g.id) inProgress else old,
    ];
    _emit();

    final runner = GameRunner(
      game: inProgress,
      participants: config.participants,
      baseSeconds: baseSeconds,
      incrementSeconds: incrementSeconds,
      ecoSeed: _ecoSeedForRound(g.round),
      enginePathFor: enginePathFor,
      onUpdate: (updated) {
        _games = [
          for (final old in _games)
            if (old.id == updated.id) updated else old,
        ];
        if (updated.status == TournamentGameStatus.finished) {
          _currentRound = _computeCurrentRound();
        }
        _emit();
      },
    );
    _running.add(runner);
    unawaited(runner.run());
  }

  Future<void> _runKnockout() async {
    var activeIds = _seededIds(config.participants);
    _games = <TournamentGame>[];
    _totalRounds = _knockoutRoundCount(activeIds.length);
    _currentRound = activeIds.length <= 1 ? 0 : 1;
    _emit();

    var round = 1;
    while (!_stopped && activeIds.length > 1) {
      if (config.knockoutReseeding == KnockoutReseeding.reseedEachRound) {
        activeIds = _seededIds(
          [for (final id in activeIds) _participantById(id)].nonNulls.toList(),
        );
      }
      final byes = <String>[];
      final roundGames = _knockoutRound(activeIds, round: round, byes: byes);
      _games = [..._games, ...roundGames];
      _concurrency = max(
        _concurrency,
        _maxEngineGamesInRound(round),
      ).clamp(1, 8);
      _currentRound = round;
      _emit();

      await _runRoundUntilIdle(round);
      if (_stopped) break;

      final winners = <String>[...byes];
      final baseGames = _games
          .where((g) => g.round == round && g.tiebreakLabel == null)
          .toList(growable: false);
      for (final g in baseGames) {
        final winner = await _winnerForKnockout(g, round: round);
        if (winner != null) winners.add(winner);
      }
      activeIds = winners;
      round++;
    }

    _completed = !_stopped && activeIds.length <= 1;
    _currentRound = _totalRounds;
    _emit();
  }

  Future<void> _runRoundUntilIdle(int round) async {
    while (!_stopped) {
      _pruneFinished();
      final next = _nextScheduled(round: round);
      final roundRunning = _running.any((r) => r.round == round);
      if (next == null && !roundRunning) {
        if (_hasUnfinishedGames(round: round)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        break;
      }
      final roundConcurrency = max(_concurrency, _maxEngineGamesInRound(round));
      while (_running.length < roundConcurrency) {
        final scheduled = _nextScheduled(round: round);
        if (scheduled == null) break;
        _startGame(scheduled);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  int _knockoutRoundCount(int participants) {
    if (participants <= 1) return 0;
    var rounds = 0;
    var slots = 1;
    while (slots < participants) {
      slots *= 2;
      rounds++;
    }
    return rounds;
  }

  List<TournamentGame> _knockoutRound(
    List<String> ids, {
    required int round,
    required List<String> byes,
  }) {
    final rng = Random();
    final games = <TournamentGame>[];
    var bracketSlots = 1;
    while (bracketSlots < ids.length) {
      bracketSlots *= 2;
    }
    final byeCount = bracketSlots - ids.length;
    byes.addAll(ids.take(byeCount));
    final pairedIds = ids.skip(byeCount).toList(growable: false);
    var left = 0;
    var right = pairedIds.length - 1;
    while (left < right) {
      games.add(
        TournamentGame(
          id: 'g${rng.nextInt(0x7FFFFFFF)}',
          round: round,
          whiteId: pairedIds[left],
          blackId: pairedIds[right],
          status: TournamentGameStatus.scheduled,
        ),
      );
      left++;
      right--;
    }
    return games;
  }

  Future<String?> _winnerForKnockout(
    TournamentGame game, {
    required int round,
  }) async {
    final direct = _directWinner(game);
    if (direct != null) return direct;

    switch (config.knockoutTiebreakMode) {
      case KnockoutTiebreakMode.higherEloAdvances:
        return _higherEloParticipant(game.whiteId, game.blackId);
      case KnockoutTiebreakMode.armageddonOnly:
        return _runArmageddon(game, round: round);
      case KnockoutTiebreakMode.rematchThenArmageddon:
        final rematch = _makeTiebreakGame(
          source: game,
          round: round,
          label: 'Tiebreak rematch',
          whiteId: game.blackId,
          blackId: game.whiteId,
          baseSeconds: _tiebreakBaseSeconds(),
          incrementSeconds: _tiebreakIncrementSeconds(),
        );
        _games = [..._games, rematch];
        _emit();
        await _runRoundUntilIdle(round);
        final resolved = _directWinner(
          _games.firstWhere((g) => g.id == rematch.id),
        );
        if (resolved != null) return resolved;
        return _runArmageddon(game, round: round);
    }
  }

  String? _directWinner(TournamentGame game) {
    switch (game.result) {
      case '1-0':
        return game.whiteId;
      case '0-1':
        return game.blackId;
      case '1/2-1/2':
        return game.drawAdvancesParticipantId;
      case '*':
      case null:
        return null;
    }
    return null;
  }

  Future<String?> _runArmageddon(
    TournamentGame source, {
    required int round,
  }) async {
    final drawOdds = _higherEloParticipant(source.whiteId, source.blackId);
    final whiteId =
        drawOdds == source.whiteId ? source.blackId : source.whiteId;
    final blackId = drawOdds;
    final armageddon = _makeTiebreakGame(
      source: source,
      round: round,
      label: 'Armageddon',
      whiteId: whiteId,
      blackId: blackId,
      baseSeconds: (_tiebreakBaseSeconds() * 0.8).round().clamp(30, 300),
      incrementSeconds: 0,
      drawAdvancesParticipantId: blackId,
    );
    _games = [..._games, armageddon];
    _emit();
    await _runRoundUntilIdle(round);
    return _directWinner(_games.firstWhere((g) => g.id == armageddon.id));
  }

  TournamentGame _makeTiebreakGame({
    required TournamentGame source,
    required int round,
    required String label,
    required String whiteId,
    required String blackId,
    required int baseSeconds,
    required int incrementSeconds,
    String? drawAdvancesParticipantId,
  }) {
    return TournamentGame(
      id: '${source.id}-tb-${Random().nextInt(0x7FFFFFFF)}',
      round: round,
      whiteId: whiteId,
      blackId: blackId,
      status: TournamentGameStatus.scheduled,
      baseSecondsOverride: baseSeconds,
      incrementSecondsOverride: incrementSeconds,
      drawAdvancesParticipantId: drawAdvancesParticipantId,
      tiebreakLabel: label,
    );
  }

  int _tiebreakBaseSeconds() => config.baseSeconds.clamp(60, 300);

  int _tiebreakIncrementSeconds() => config.incrementSeconds.clamp(0, 2);

  String _higherEloParticipant(String a, String b) {
    final pa = _participantById(a);
    final pb = _participantById(b);
    if ((pa?.identity.elo ?? 0) >= (pb?.identity.elo ?? 0)) return a;
    return b;
  }

  List<String> _seededIds(List<TournamentParticipant> participants) {
    final seeded = [...participants];
    seeded.sort((a, b) => b.identity.elo.compareTo(a.identity.elo));
    return [for (final p in seeded) p.id];
  }

  TournamentParticipant? _participantById(String id) {
    for (final participant in config.participants) {
      if (participant.id == id) return participant;
    }
    return null;
  }

  int _computeCurrentRound() {
    if (_games.isEmpty) return 0;
    int? lowestUnfinished;
    var maxRound = 0;
    for (final g in _games) {
      if (g.round > maxRound) maxRound = g.round;
      if (g.status != TournamentGameStatus.finished) {
        lowestUnfinished =
            lowestUnfinished == null ? g.round : min(lowestUnfinished, g.round);
      }
    }
    return lowestUnfinished ?? maxRound;
  }

  List<TournamentGame>? _resumableGames(List<TournamentGame>? games) {
    if (games == null) return null;
    return [
      for (final game in games)
        if (game.status == TournamentGameStatus.inProgress)
          game.copyWith(status: TournamentGameStatus.scheduled)
        else
          game,
    ];
  }

  int _maxEngineGamesInAnyRound() {
    var maxGames = 1;
    for (var round = 1; round <= _totalRounds; round++) {
      maxGames = max(maxGames, _maxEngineGamesInRound(round));
    }
    return maxGames;
  }

  int _maxEngineGamesInRound(int round) {
    var games = 0;
    for (final game in _games) {
      if (game.round == round && !_isHumanGame(game)) games++;
    }
    return games.clamp(1, 8);
  }

  EcoOpeningSeed? _ecoSeedForRound(int round) {
    if (config.ecoLines.isEmpty) return null;
    return config.ecoLines[(round - 1) % config.ecoLines.length];
  }

  void _emit() {
    final standings = _computeStandings();
    onSnapshotChange(
      TournamentSnapshot(
        config: config,
        games: _games,
        standings: standings,
        currentRound: _currentRound,
        totalRounds: _totalRounds,
        isRunning: !_stopped && !_completed,
        resourceAssessment: _resourceAssessment,
      ),
    );
  }

  List<TournamentStanding> _computeStandings() {
    final pts = <String, double>{};
    final played = <String, int>{};
    for (final p in config.participants) {
      pts[p.id] = 0.0;
      played[p.id] = 0;
    }
    for (final g in _games) {
      if (g.status != TournamentGameStatus.finished) continue;
      played[g.whiteId] = (played[g.whiteId] ?? 0) + 1;
      played[g.blackId] = (played[g.blackId] ?? 0) + 1;
      switch (g.result) {
        case '1-0':
          pts[g.whiteId] = (pts[g.whiteId] ?? 0) + 1;
          break;
        case '0-1':
          pts[g.blackId] = (pts[g.blackId] ?? 0) + 1;
          break;
        case '1/2-1/2':
          pts[g.whiteId] = (pts[g.whiteId] ?? 0) + 0.5;
          pts[g.blackId] = (pts[g.blackId] ?? 0) + 0.5;
          break;
      }
    }
    final standings = [
      for (final p in config.participants)
        TournamentStanding(
          participantId: p.id,
          points: pts[p.id] ?? 0,
          played: played[p.id] ?? 0,
        ),
    ];
    standings.sort((a, b) {
      final c = b.points.compareTo(a.points);
      if (c != 0) return c;
      return b.played.compareTo(a.played);
    });
    return standings;
  }

  // --- pairing ---

  List<TournamentGame> _buildSchedule(TournamentConfig cfg) {
    final ids = [for (final p in cfg.participants) p.id];
    switch (cfg.format) {
      case TournamentFormat.roundRobin:
        return _roundRobin(ids, double_: false);
      case TournamentFormat.doubleRoundRobin:
        return _roundRobin(ids, double_: true);
      case TournamentFormat.knockout:
        return _knockoutBracket(ids);
    }
  }

  List<TournamentGame> _roundRobin(List<String> ids, {required bool double_}) {
    final players = [...ids];
    final hadBye = players.length.isOdd;
    if (hadBye) players.add('_BYE_');
    final n = players.length;
    final rounds = <List<List<String>>>[];
    final list = [...players];
    for (var r = 0; r < n - 1; r++) {
      final pairings = <List<String>>[];
      for (var i = 0; i < n ~/ 2; i++) {
        final a = list[i];
        final b = list[n - 1 - i];
        if (a == '_BYE_' || b == '_BYE_') continue;
        // Alternate colors per round so each player gets roughly equal whites.
        final whiteFirst = (r + i).isEven;
        pairings.add(whiteFirst ? [a, b] : [b, a]);
      }
      rounds.add(pairings);
      // Rotate, holding list[0] fixed.
      final last = list.removeLast();
      list.insert(1, last);
    }
    final games = <TournamentGame>[];
    final rng = Random();
    for (var r = 0; r < rounds.length; r++) {
      for (final pair in rounds[r]) {
        games.add(
          TournamentGame(
            id: 'g${rng.nextInt(0x7FFFFFFF)}',
            round: r + 1,
            whiteId: pair[0],
            blackId: pair[1],
            status: TournamentGameStatus.scheduled,
          ),
        );
      }
    }
    if (double_) {
      // Mirror with reversed colors after the first cycle.
      final mirrored = <TournamentGame>[];
      final startRound = rounds.length;
      for (var r = 0; r < rounds.length; r++) {
        for (final pair in rounds[r]) {
          mirrored.add(
            TournamentGame(
              id: 'g${rng.nextInt(0x7FFFFFFF)}',
              round: startRound + r + 1,
              whiteId: pair[1],
              blackId: pair[0],
              status: TournamentGameStatus.scheduled,
            ),
          );
        }
      }
      games.addAll(mirrored);
    }
    return games;
  }

  List<TournamentGame> _knockoutBracket(List<String> ids) {
    // First-round seeds: 1v(n), 2v(n-1), … Subsequent rounds are populated
    // lazily as games resolve; for now we emit only the first round so the
    // standings view shows something. Re-seeding is conductor logic we'll
    // run between rounds in a future pass (tracked: see runner.onUpdate).
    final pairs = <TournamentGame>[];
    final rng = Random();
    final n = ids.length;
    for (var i = 0; i < n ~/ 2; i++) {
      pairs.add(
        TournamentGame(
          id: 'g${rng.nextInt(0x7FFFFFFF)}',
          round: 1,
          whiteId: ids[i],
          blackId: ids[n - 1 - i],
          status: TournamentGameStatus.scheduled,
        ),
      );
    }
    return pairs;
  }
}

/// Drives a single game inside the tournament: spawns two engines, alternates
/// `go` commands, applies moves to a dartchess [Position], tracks Fischer
/// clocks, ends on time / mate / agreed result.
class GameRunner {
  GameRunner({
    required this.game,
    required this.participants,
    required this.baseSeconds,
    required this.incrementSeconds,
    required this.enginePathFor,
    required this.onUpdate,
    this.ecoSeed,
  });

  final TournamentGame game;
  final List<TournamentParticipant> participants;
  final int baseSeconds;
  final int incrementSeconds;
  final EcoOpeningSeed? ecoSeed;
  final String? Function(BotEngineKind) enginePathFor;
  final void Function(TournamentGame) onUpdate;

  _TournamentEngine? _white;
  _TournamentEngine? _black;
  bool finished = false;

  int get round => game.round;

  TournamentParticipant get _whitePart =>
      participants.firstWhere((p) => p.id == game.whiteId);
  TournamentParticipant get _blackPart =>
      participants.firstWhere((p) => p.id == game.blackId);

  Future<void> cancel() async {
    finished = true;
    await _white?.dispose();
    await _black?.dispose();
  }

  Future<void> run() async {
    final whitePath = enginePathFor(_whitePart.engine);
    final blackPath = enginePathFor(_blackPart.engine);
    if (whitePath == null || blackPath == null) {
      _finish(
        game.copyWith(
          status: TournamentGameStatus.finished,
          result: '*',
          endReason: 'engine binary missing',
        ),
      );
      return;
    }
    final startingFen = game.startingFen ?? ecoSeed?.fen ?? Chess.initial.fen;
    final movesSoFar = _initialMoves();
    final rootFen = _rootFenFor(movesSoFar, startingFen);
    var position = _initialPosition(startingFen, movesSoFar);
    var whiteMs = game.whiteMillis ?? baseSeconds * 1000;
    var blackMs = game.blackMillis ?? baseSeconds * 1000;
    var clockUpdatedAt = DateTime.now();
    var current = game.copyWith(
      status: TournamentGameStatus.inProgress,
      result: '*',
      fen: position.fen,
      whiteMillis: whiteMs,
      blackMillis: blackMs,
      movesUci: movesSoFar,
      startingFen: startingFen,
      ecoLine: ecoSeed?.label,
      clockUpdatedAt: clockUpdatedAt,
    );

    try {
      _white = await _bootEngine(whitePath, _whitePart);
      _black = await _bootEngine(blackPath, _blackPart);
    } catch (e) {
      _finish(
        current.copyWith(
          status: TournamentGameStatus.finished,
          result: '*',
          endReason: 'engine boot failed: $e',
        ),
      );
      return;
    }

    onUpdate(current);

    while (!finished) {
      if (position.isGameOver) break;
      final mover = position.turn;
      final engine = mover == Side.white ? _white! : _black!;
      final start = DateTime.now();
      final bestmove = await engine.bestMove(
        position: position,
        rootFen: rootFen,
        movesSoFar: movesSoFar,
        whiteMillis: whiteMs,
        blackMillis: blackMs,
        incrementMillis: incrementSeconds * 1000,
        baseMillis: baseSeconds * 1000,
        ply: movesSoFar.length,
        timeout: const Duration(seconds: 90),
      );
      if (finished) return;
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      clockUpdatedAt = DateTime.now();
      if (bestmove == null) {
        // Engine hung; award the loss to make progress.
        _finish(
          current.copyWith(
            status: TournamentGameStatus.finished,
            result: mover == Side.white ? '0-1' : '1-0',
            endReason: 'engine timeout',
            clockUpdatedAt: clockUpdatedAt,
          ),
        );
        return;
      }
      // Apply clock delta first.
      if (mover == Side.white) {
        whiteMs = (whiteMs - elapsed).clamp(0, 1 << 31);
        if (whiteMs <= 0) {
          _finish(
            current.copyWith(
              status: TournamentGameStatus.finished,
              result: '0-1',
              endReason: 'white flagged',
              whiteMillis: 0,
              blackMillis: blackMs,
              fen: position.fen,
              movesUci: movesSoFar,
              clockUpdatedAt: clockUpdatedAt,
            ),
          );
          return;
        }
        whiteMs += incrementSeconds * 1000;
      } else {
        blackMs = (blackMs - elapsed).clamp(0, 1 << 31);
        if (blackMs <= 0) {
          _finish(
            current.copyWith(
              status: TournamentGameStatus.finished,
              result: '1-0',
              endReason: 'black flagged',
              whiteMillis: whiteMs,
              blackMillis: 0,
              fen: position.fen,
              movesUci: movesSoFar,
              clockUpdatedAt: clockUpdatedAt,
            ),
          );
          return;
        }
        blackMs += incrementSeconds * 1000;
      }
      final move = _safeParse(bestmove, position);
      if (move == null) {
        // Engine produced an illegal move — count as a loss for the mover.
        _finish(
          current.copyWith(
            status: TournamentGameStatus.finished,
            result: mover == Side.white ? '0-1' : '1-0',
            endReason: 'engine illegal move ($bestmove)',
            clockUpdatedAt: clockUpdatedAt,
          ),
        );
        return;
      }
      position = position.play(move);
      movesSoFar.add(bestmove);
      current = current.copyWith(
        status: TournamentGameStatus.inProgress,
        result: '*',
        fen: position.fen,
        lastMoveUci: bestmove,
        movesUci: movesSoFar,
        whiteMillis: whiteMs,
        blackMillis: blackMs,
        clockUpdatedAt: clockUpdatedAt,
      );
      onUpdate(current);
      // 200ms breather so the UI tick isn't drowned and CPU has air.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    // Natural finish.
    final outcome = position.outcome;
    final result =
        outcome == Outcome.whiteWins
            ? '1-0'
            : outcome == Outcome.blackWins
            ? '0-1'
            : '1/2-1/2';
    _finish(
      current.copyWith(
        status: TournamentGameStatus.finished,
        result: result,
        fen: position.fen,
        movesUci: movesSoFar,
        whiteMillis: whiteMs,
        blackMillis: blackMs,
        clockUpdatedAt: DateTime.now(),
        endReason:
            position.isCheckmate
                ? 'checkmate'
                : position.isStalemate
                ? 'stalemate'
                : 'draw',
      ),
    );
  }

  List<String> _initialMoves() {
    if (game.movesUci.isNotEmpty) return List<String>.from(game.movesUci);
    return List<String>.from(ecoSeed?.moveSequence ?? const <String>[]);
  }

  String _rootFenFor(List<String> movesSoFar, String startingFen) {
    final ecoMoves = ecoSeed?.moveSequence ?? const <String>[];
    if (ecoMoves.isNotEmpty && _startsWith(movesSoFar, ecoMoves)) {
      return Chess.initial.fen;
    }
    return startingFen;
  }

  Position _initialPosition(String startingFen, List<String> movesSoFar) {
    final existingFen = game.fen;
    if (existingFen != null && existingFen.isNotEmpty) {
      return Position.setupPosition(Rule.chess, Setup.parseFen(existingFen));
    }
    return Position.setupPosition(Rule.chess, Setup.parseFen(startingFen));
  }

  bool _startsWith(List<String> values, List<String> prefix) {
    if (values.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (values[i] != prefix[i]) return false;
    }
    return true;
  }

  Future<_TournamentEngine> _bootEngine(
    String path,
    TournamentParticipant part,
  ) async {
    if (part.engine == BotEngineKind.maia && isMaia3ModelPath(path)) {
      return _TournamentEngine.maia(
        await Maia3LocalEngine.load(path),
        elo: part.identity.elo,
      );
    }

    final engine = await UciEngine.spawn(
      path,
      arguments: engineLaunchArguments(part.engine, path, part.identity.elo),
      workingDirectory: engineWorkingDirectory(path),
    );
    await engine.initialize(
      threads: 1,
      hashMb: part.engine == BotEngineKind.stockfish ? 32 : null,
      multiPv: 1,
    );
    for (final command in engineStrengthOptionCommands(
      part.engine,
      part.identity.elo,
    )) {
      engine.send(command);
    }
    engine.send('ucinewgame');
    engine.send('isready');
    return _TournamentEngine.uci(
      engine,
      kind: part.engine,
      elo: part.identity.elo,
    );
  }

  Move? _safeParse(String uci, Position position) {
    try {
      final m = NormalMove.fromUci(uci);
      if (!position.isLegal(m)) return null;
      return m;
    } catch (_) {
      return null;
    }
  }

  void _finish(TournamentGame g) {
    finished = true;
    onUpdate(g);
    unawaited(_white?.dispose());
    unawaited(_black?.dispose());
    _white = null;
    _black = null;
  }
}

class _TournamentEngine {
  _TournamentEngine.uci(
    UciEngine engine, {
    required this.kind,
    required this.elo,
  }) : _uci = engine,
       _maia = null;

  _TournamentEngine.maia(Maia3LocalEngine engine, {required this.elo})
    : kind = BotEngineKind.maia,
      _uci = null,
      _maia = engine;

  final BotEngineKind kind;
  final UciEngine? _uci;
  final Maia3LocalEngine? _maia;
  final int elo;
  final Random _random = Random();

  Future<String?> bestMove({
    required Position position,
    required String rootFen,
    required List<String> movesSoFar,
    required int whiteMillis,
    required int blackMillis,
    required int incrementMillis,
    required int baseMillis,
    required int ply,
    required Duration timeout,
  }) async {
    final maia = _maia;
    if (maia != null) {
      final ownMillis = position.turn == Side.white ? whiteMillis : blackMillis;
      final thinkMillis = clockAwareMoveTimeMillis(
        elo: elo,
        ownMillis: ownMillis,
        incrementMillis: incrementMillis,
        baseMillis: baseMillis,
        ply: ply,
        random: _random,
      );
      final move = await maia.pickMove(
        fen: position.fen,
        eloSelf: elo,
        eloOpponent: elo,
      );
      await Future<void>.delayed(Duration(milliseconds: thinkMillis));
      return move;
    }

    final engine = _uci;
    if (engine == null) return null;
    final movesUci = movesSoFar.join(' ');
    final positionCmd =
        rootFen == Chess.initial.fen
            ? (movesUci.isEmpty
                ? 'position startpos'
                : 'position startpos moves $movesUci')
            : (movesUci.isEmpty
                ? 'position fen $rootFen'
                : 'position fen $rootFen moves $movesUci');
    engine.send(positionCmd);
    engine.send(
      engineGoCommand(
        kind,
        elo: elo,
        whiteMillis: whiteMillis,
        blackMillis: blackMillis,
        incrementMillis: incrementMillis,
        sideToMove: position.turn,
        baseMillis: baseMillis,
        ply: ply,
        random: _random,
      ),
    );
    return _awaitBestmove(engine, timeout: timeout);
  }

  Future<String?> _awaitBestmove(
    UciEngine engine, {
    required Duration timeout,
  }) async {
    final completer = Completer<String?>();
    late StreamSubscription<String> sub;
    sub = engine.lines.listen((line) {
      if (line.startsWith('bestmove')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2 && !completer.isCompleted) {
          completer.complete(parts[1]);
        }
      }
    });
    final result = await completer.future.timeout(
      timeout,
      onTimeout: () => null,
    );
    await sub.cancel();
    return result;
  }

  Future<void> dispose() async {
    final uci = _uci;
    if (uci != null) {
      try {
        uci.send('stop');
        uci.send('quit');
      } catch (_) {}
      await uci.dispose();
      return;
    }
    await _maia?.dispose();
  }
}

/// Singleton-style provider for the server. The desktop shell mounts this
/// once at startup; UI components read it to drive Start/Stop controls and
/// snapshot rendering.
final tournamentServerProvider =
    StateNotifierProvider<TournamentServer, TournamentServerState>((ref) {
      final server = TournamentServer();
      ref.onDispose(() => unawaited(server.stop()));
      // Wire engine resolver from the engineInstallProvider so the conductor
      // can find binaries without taking a Riverpod dependency itself.
      server.setEnginePathResolver((kind) {
        final state = ref.read(engineInstallProvider(kind));
        return engineReady(state) ? state.binaryPath : null;
      });
      return server;
    });
