import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_access.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/utils/local_pgn_metadata.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class LocalRawPgnCatalogPageQuery {
  const LocalRawPgnCatalogPageQuery({
    required this.descriptor,
    this.search = '',
    this.sortBy = LocalChessGameSortField.originalOrder,
    this.sortDirection = LocalChessGameSortDirection.asc,
    this.filter,
    this.playerFideId,
    this.playerAliases = const <String>[],
    required this.pageNumber,
    required this.pageSize,
  });

  final LocalRawPgnCatalogDescriptor descriptor;
  final String search;
  final LocalChessGameSortField sortBy;
  final LocalChessGameSortDirection sortDirection;
  final LocalChessGameFilter? filter;
  final String? playerFideId;
  final List<String> playerAliases;
  final int pageNumber;
  final int pageSize;
}

class LocalRawPgnCatalogHandle {
  LocalRawPgnCatalogHandle._(this._session, this.descriptor, this.source);

  final _RawPgnCatalogSession _session;
  final LocalRawPgnCatalogDescriptor descriptor;
  final LocalChessSource source;
  var _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _session.release();
  }
}

Future<LocalRawPgnCatalogHandle> openLocalRawPgnCatalog(
  String path, {
  String? sourceLabel,
  Duration inactivityTimeout = const Duration(minutes: 5),
  OperationCancellationToken? cancellationToken,
  Duration? debugWorkerStartDelay,
  Duration? debugValidationDelay,
  void Function(LocalChessScanProgress progress)? onProgress,
}) {
  return _rawPgnCatalogManager.open(
    path,
    sourceLabel: sourceLabel,
    inactivityTimeout: inactivityTimeout,
    cancellationToken: cancellationToken,
    debugWorkerStartDelay: debugWorkerStartDelay,
    debugValidationDelay: debugValidationDelay,
    onProgress: onProgress,
  );
}

Future<LocalChessGameQueryPage?> localRawPgnCatalogPage(
  LocalRawPgnCatalogPageQuery query,
) {
  return _rawPgnCatalogManager.page(query);
}

final _rawPgnCatalogManager = _RawPgnCatalogManager();

const _defaultMaxIdleRawPgnCatalogSessions = 2;
const _defaultMaxIdleRawPgnCatalogSourceBytes = 256 * 1024 * 1024;
const _defaultMaxIdleRawPgnCatalogRows = 250000;

var _maxIdleRawPgnCatalogSessions = _defaultMaxIdleRawPgnCatalogSessions;
var _maxIdleRawPgnCatalogSourceBytes =
    _defaultMaxIdleRawPgnCatalogSourceBytes;
var _maxIdleRawPgnCatalogRows = _defaultMaxIdleRawPgnCatalogRows;

@visibleForTesting
void debugConfigureLocalRawPgnCatalogLimits({
  int? maxIdleSessions,
  int? maxIdleSourceBytes,
  int? maxIdleRows,
}) {
  _maxIdleRawPgnCatalogSessions =
      maxIdleSessions ?? _defaultMaxIdleRawPgnCatalogSessions;
  _maxIdleRawPgnCatalogSourceBytes =
      maxIdleSourceBytes ?? _defaultMaxIdleRawPgnCatalogSourceBytes;
  _maxIdleRawPgnCatalogRows =
      maxIdleRows ?? _defaultMaxIdleRawPgnCatalogRows;
  _rawPgnCatalogManager.enforceIdleBoundsForTest();
}

@visibleForTesting
Map<String, Object?> debugLocalRawPgnCatalogState(String path) =>
    _rawPgnCatalogManager.debugState(path);

@visibleForTesting
void debugCloseLocalRawPgnCatalogs() => _rawPgnCatalogManager.closeAllForTest();

class _RawPgnCatalogManager {
  final _sessions = <String, _RawPgnCatalogSession>{};
  final _opening = <String, _RawPgnCatalogOpening>{};

  Future<LocalRawPgnCatalogHandle> open(
    String path, {
    String? sourceLabel,
    required Duration inactivityTimeout,
    OperationCancellationToken? cancellationToken,
    Duration? debugWorkerStartDelay,
    Duration? debugValidationDelay,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    cancellationToken?.throwIfCanceled();
    final normalized = File(path).absolute.path;
    final existing = _sessions[normalized];
    if (existing != null) {
      if (existing.retain()) {
        var keepRetained = false;
        try {
          if (await existing.isFresh(strong: true)) {
            cancellationToken?.throwIfCanceled();
            keepRetained = true;
            return LocalRawPgnCatalogHandle._(
              existing,
              existing.descriptor,
              existing.source,
            );
          }
        } finally {
          if (!keepRetained) existing.release();
        }
      }
      if (identical(_sessions[normalized], existing)) {
        _sessions.remove(normalized);
      }
      if (!existing.isActive) existing.close();
    }
    cancellationToken?.throwIfCanceled();
    final opening = _opening.putIfAbsent(
      normalized,
      () => _RawPgnCatalogOpening.start(
        normalized,
        sourceLabel: sourceLabel,
        inactivityTimeout: inactivityTimeout,
        debugWorkerStartDelay: debugWorkerStartDelay,
        debugValidationDelay: debugValidationDelay,
        onProgress: onProgress,
      ),
    );
    late final _RawPgnCatalogSession session;
    try {
      session = await opening.wait(cancellationToken);
    } finally {
      if (opening.canForget && identical(_opening[normalized], opening)) {
        _opening.remove(normalized);
      }
    }
    _sessions[normalized] = session;
    session.retain();
    return LocalRawPgnCatalogHandle._(
      session,
      session.descriptor,
      session.source,
    );
  }

  Future<LocalChessGameQueryPage?> page(
    LocalRawPgnCatalogPageQuery query,
  ) async {
    final normalized = File(query.descriptor.path).absolute.path;
    final session = _sessions[normalized];
    if (session == null ||
        session.descriptor.sessionId != query.descriptor.sessionId) {
      return Future<LocalChessGameQueryPage?>.value(null);
    }
    final wasIdle = session.isIdle;
    if (!session.retain()) return null;
    try {
      if (!identical(_sessions[normalized], session) ||
          session.descriptor.sessionId != query.descriptor.sessionId) {
        return null;
      }
      // Concurrent page/open pins are not proof that idle validation finished.
      final validation = wasIdle
          ? session.isFresh(strong: true)
          : session._strongFreshValidation;
      if (validation != null && !await validation) return null;
      if (!identical(_sessions[normalized], session) ||
          session.descriptor.sessionId != query.descriptor.sessionId) {
        return null;
      }
      return await session.page(query);
    } finally {
      session.release();
    }
  }

  void forget(_RawPgnCatalogSession session) {
    final key = File(session.descriptor.path).absolute.path;
    if (identical(_sessions[key], session)) _sessions.remove(key);
  }

  void sessionBecameIdle(_RawPgnCatalogSession session) {
    if (!_contains(session)) {
      if (session.isIdle) session.close();
      return;
    }
    _enforceIdleBounds();
  }

  void expireIdle(_RawPgnCatalogSession session) {
    if (session.isActive) return;
    if (!_contains(session)) {
      session.close();
      return;
    }
    session.close();
  }

  bool _contains(_RawPgnCatalogSession session) {
    final key = File(session.descriptor.path).absolute.path;
    return identical(_sessions[key], session);
  }

  void _enforceIdleBounds() {
    final idle = _sessions.values
        .where((session) => session.isIdle)
        .toList(growable: false)
      ..sort((a, b) => a.lastIdleAt.compareTo(b.lastIdleAt));
    var idleCount = idle.length;
    var idleBytes = idle.fold<int>(
      0,
      (sum, session) => sum + session.descriptor.fileSizeBytes,
    );
    var idleRows = idle.fold<int>(
      0,
      (sum, session) => sum + session.descriptor.totalGames,
    );
    for (final session in idle) {
      if (idleCount <= _maxIdleRawPgnCatalogSessions &&
          idleBytes <= _maxIdleRawPgnCatalogSourceBytes &&
          idleRows <= _maxIdleRawPgnCatalogRows) {
        break;
      }
      if (session.isActive) continue;
      idleCount--;
      idleBytes -= session.descriptor.fileSizeBytes;
      idleRows -= session.descriptor.totalGames;
      session.close();
    }
  }

  void enforceIdleBoundsForTest() => _enforceIdleBounds();

  Map<String, Object?> debugState(String path) {
    final session = _sessions[File(path).absolute.path];
    return <String, Object?>{
      'sessionCount': _sessions.length,
      'hasSession': session != null,
      'refCount': session?._refCount,
      'isClosed': session?._closed,
      'isIdle': session?.isIdle,
      'sessionId': session?.descriptor.sessionId,
    };
  }

  void closeAllForTest() {
    for (final session in _sessions.values.toList(growable: false)) {
      session.close();
    }
    _sessions.clear();
    _opening.clear();
    _maxIdleRawPgnCatalogSessions = _defaultMaxIdleRawPgnCatalogSessions;
    _maxIdleRawPgnCatalogSourceBytes =
        _defaultMaxIdleRawPgnCatalogSourceBytes;
    _maxIdleRawPgnCatalogRows = _defaultMaxIdleRawPgnCatalogRows;
  }
}

class _RawPgnCatalogOpening {
  _RawPgnCatalogOpening._(this.future);

  final Future<_RawPgnCatalogSession> future;
  final _cancelReady = Completer<void>();
  Isolate? _isolate;
  var _waiters = 0;
  var _settled = false;

  bool get isSettled => _settled;
  bool get canForget => _settled || (_cancelReady.isCompleted && _waiters <= 0);

  static _RawPgnCatalogOpening start(
    String path, {
    String? sourceLabel,
    required Duration inactivityTimeout,
    Duration? debugWorkerStartDelay,
    Duration? debugValidationDelay,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) {
    late final _RawPgnCatalogOpening opening;
    opening = _RawPgnCatalogOpening._(
      _RawPgnCatalogSession.start(
        path,
        sourceLabel: sourceLabel,
        inactivityTimeout: inactivityTimeout,
        debugWorkerStartDelay: debugWorkerStartDelay,
        debugValidationDelay: debugValidationDelay,
        onProgress: onProgress,
        onIsolate: (isolate) {
          opening._isolate = isolate;
          if (opening._cancelReady.isCompleted) {
            isolate.kill(priority: Isolate.immediate);
          }
        },
        cancelReady: () => opening._cancelReady.future,
      ).whenComplete(() => opening._settled = true),
    );
    opening.future.ignore();
    return opening;
  }

  Future<_RawPgnCatalogSession> wait(
    OperationCancellationToken? cancellationToken,
  ) async {
    cancellationToken?.throwIfCanceled();
    _waiters++;
    var active = true;
    void cancelWaiter() {
      if (!active) return;
      active = false;
      _waiters--;
      if (_waiters <= 0 && !_settled) {
        if (!_cancelReady.isCompleted) _cancelReady.complete();
        _isolate?.kill(priority: Isolate.immediate);
      }
    }

    final removeListener = cancellationToken?.addListener(cancelWaiter);
    try {
      if (cancellationToken == null) return await future;
      return await Future.any<_RawPgnCatalogSession>([
        future,
        cancellationToken.whenCanceled.then<_RawPgnCatalogSession>(
          (_) => throw const OperationCanceledException(),
        ),
      ]);
    } finally {
      removeListener?.call();
      if (active) {
        active = false;
        _waiters--;
      }
    }
  }
}

class _RawPgnCatalogSession {
  _RawPgnCatalogSession._({
    required this.descriptor,
    required this.source,
    required SendPort requests,
    required ReceivePort replies,
    required StreamSubscription<dynamic> subscription,
    required Isolate isolate,
    required Duration inactivityTimeout,
  }) : _requests = requests,
       _replies = replies,
       _subscription = subscription,
       _isolate = isolate,
       _inactivityTimeout = inactivityTimeout;

  final LocalRawPgnCatalogDescriptor descriptor;
  final LocalChessSource source;
  final SendPort _requests;
  final ReceivePort _replies;
  final StreamSubscription<dynamic> _subscription;
  final Isolate _isolate;
  final Duration _inactivityTimeout;
  final _pending = <int, Completer<Object?>>{};
  Future<bool>? _strongFreshValidation;
  var _next = 0;
  var _refCount = 0;
  var _closed = false;
  var _lastIdleAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _idleTimer;

  bool get isActive => !_closed && _refCount > 0;
  bool get isIdle => !_closed && _refCount == 0;
  DateTime get lastIdleAt => _lastIdleAt;

  static Future<_RawPgnCatalogSession> start(
    String path, {
    String? sourceLabel,
    required Duration inactivityTimeout,
    Duration? debugWorkerStartDelay,
    Duration? debugValidationDelay,
    void Function(LocalChessScanProgress progress)? onProgress,
    required void Function(Isolate isolate) onIsolate,
    required Future<void> Function() cancelReady,
  }) async {
    final replies = ReceivePort();
    late final StreamSubscription<dynamic> subscription;
    _RawPgnCatalogSession? session;
    final ready = Completer<_RawPgnCatalogReady>();
    final failed = Completer<Object>();
    subscription = replies.listen((message) {
      final active = session;
      if (active != null) {
        active._receive(message);
        return;
      }
      switch (message) {
        case LocalChessScanProgress progress:
          onProgress?.call(progress);
        case _RawPgnCatalogReady readyMessage:
          if (!ready.isCompleted) ready.complete(readyMessage);
        case _RawPgnCatalogFailure(:final error):
          if (!failed.isCompleted) failed.complete(error);
        case null:
          if (!failed.isCompleted) {
            failed.complete(
              StateError('PGN catalog worker exited before ready.'),
            );
          }
        case List message:
          if (!failed.isCompleted) {
            failed.complete(RemoteError(message.toString(), ''));
          }
      }
    });
    final isolate = await Isolate.spawn(
      _runRawPgnCatalogWorker,
      _RawPgnCatalogOpenRequest(
        sendPort: replies.sendPort,
        path: path,
        sourceLabel: sourceLabel,
        inactivityTimeout: inactivityTimeout,
        debugWorkerStartDelay: debugWorkerStartDelay,
        debugValidationDelay: debugValidationDelay,
      ),
      onExit: replies.sendPort,
      onError: replies.sendPort,
      errorsAreFatal: true,
    );
    onIsolate(isolate);
    final first = await Future.any<Object>([
      ready.future,
      failed.future,
      cancelReady().then<Object>((_) => const OperationCanceledException()),
    ]);
    if (first is! _RawPgnCatalogReady) {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      replies.close();
      throw first;
    }
    session = _RawPgnCatalogSession._(
      descriptor: first.descriptor,
      source: first.source,
      requests: first.requestPort,
      replies: replies,
      subscription: subscription,
      isolate: isolate,
      inactivityTimeout: inactivityTimeout,
    );
    return session;
  }

  bool retain() {
    if (_closed) return false;
    _idleTimer?.cancel();
    _idleTimer = null;
    _refCount++;
    return true;
  }

  void release() {
    if (_refCount > 0) _refCount--;
    if (_refCount == 0 && !_closed) {
      _lastIdleAt = DateTime.now();
      _idleTimer?.cancel();
      _idleTimer = Timer(
        _inactivityTimeout,
        () => _rawPgnCatalogManager.expireIdle(this),
      );
      _rawPgnCatalogManager.sessionBecameIdle(this);
    }
  }

  Future<bool> isFresh({bool strong = false}) {
    if (strong) {
      final pending = _strongFreshValidation;
      if (pending != null) return pending;
      final future = _requestFresh(strong: true).whenComplete(() {
        _strongFreshValidation = null;
      });
      _strongFreshValidation = future;
      return future;
    }
    return _requestFresh(strong: false);
  }

  Future<bool> _requestFresh({required bool strong}) async {
    if (_closed) return false;
    final id = _next++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _requests.send([id, _RawPgnCatalogValidate(strong: strong)]);
    final value = await completer.future;
    return value == true;
  }

  Future<LocalChessGameQueryPage?> page(LocalRawPgnCatalogPageQuery query) {
    if (_closed) return Future<LocalChessGameQueryPage?>.value(null);
    final id = _next++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _requests.send([id, query]);
    return completer.future.then((value) => value as LocalChessGameQueryPage?);
  }

  void _receive(dynamic message) {
    if (_closed) return;
    if (message == null) {
      close();
      return;
    }
    if (message is! List || message.first is! int) return;
    final completer = _pending.remove(message.first as int);
    if (completer == null) return;
    switch (message[1]) {
      case 'ok':
        completer.complete(message[2] as LocalChessGameQueryPage);
      case 'stale':
        completer.complete(null);
      case 'fresh':
        completer.complete(message[2] as bool);
      case 'state':
        completer.completeError(StateError(message[2] as String));
      default:
        completer.completeError(
          RemoteError(message[2].toString(), message[3].toString()),
        );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _rawPgnCatalogManager.forget(this);
    _requests.send(const _RawPgnCatalogClose());
    _isolate.kill(priority: Isolate.immediate);
    _subscription.cancel().ignore();
    _replies.close();
    for (final completer in _pending.values) {
      completer.complete(null);
    }
    _pending.clear();
  }
}

class _RawPgnCatalogOpenRequest {
  const _RawPgnCatalogOpenRequest({
    required this.sendPort,
    required this.path,
    required this.sourceLabel,
    required this.inactivityTimeout,
    required this.debugWorkerStartDelay,
    required this.debugValidationDelay,
  });

  final SendPort sendPort;
  final String path;
  final String? sourceLabel;
  final Duration inactivityTimeout;
  final Duration? debugWorkerStartDelay;
  final Duration? debugValidationDelay;
}

class _RawPgnCatalogReady {
  const _RawPgnCatalogReady({
    required this.requestPort,
    required this.descriptor,
    required this.source,
  });

  final SendPort requestPort;
  final LocalRawPgnCatalogDescriptor descriptor;
  final LocalChessSource source;
}

class _RawPgnCatalogFailure {
  const _RawPgnCatalogFailure(this.error);

  final Object error;
}

class _RawPgnCatalogClose {
  const _RawPgnCatalogClose();
}

class _RawPgnCatalogValidate {
  const _RawPgnCatalogValidate({required this.strong});

  final bool strong;
}

Future<void> _runRawPgnCatalogWorker(_RawPgnCatalogOpenRequest request) async {
  final requests = ReceivePort();
  final send = request.sendPort;

  try {
    if (request.debugWorkerStartDelay != null) {
      await Future<void>.delayed(request.debugWorkerStartDelay!);
    }
    final beforeScan = await File(request.path).stat();
    final beforeScanSha256 = await _computeStableRawPgnCatalogFullSha256(
      request.path,
      expectedStat: beforeScan,
    );
    final fullSource = await scanLocalChessPgnCatalogInlineForWorker(
      request.path,
      sourceLabel: request.sourceLabel,
      maxGames: 2147483647,
      onProgress: (progress) => send.send(progress),
    );
    final fullFile = fullSource.root.files.single;
    final games = fullFile.games;
    if (fullFile.gameCount != games.length) {
      throw StateError(
        'The PGN catalog exceeded the supported entry limit. Reopen with a smaller source.',
      );
    }
    final stat = await File(request.path).stat();
    if (stat.size != beforeScan.size || stat.modified != beforeScan.modified) {
      throw StateError('The PGN file changed while its catalog was opening.');
    }
    final fingerprint = await computeLocalChessFileContentFingerprint(
      request.path,
      stat: stat,
    );
    final fullSha256 = await _computeStableRawPgnCatalogFullSha256(
      request.path,
      expectedStat: stat,
    );
    if (fullSha256 != beforeScanSha256) {
      throw StateError('The PGN file changed while its catalog was opening.');
    }
    final descriptor = LocalRawPgnCatalogDescriptor(
      sessionId: _catalogSessionId(
        request.path,
        stat,
        fingerprint,
        fullSha256,
      ),
      path: request.path,
      label: fullSource.label,
      rootPath: fullSource.rootPath,
      fileSizeBytes: stat.size,
      modifiedAt: stat.modified,
      contentFingerprint: fingerprint,
      fullSha256: fullSha256,
      totalGames: fullFile.gameCount,
    );
    final node = LocalChessFileNode(
      name: fullFile.name,
      path: fullFile.path,
      relativePath: fullFile.relativePath,
      extension: fullFile.extension,
      status: fullFile.status,
      games: const <LocalChessGame>[],
      sizeBytes: fullFile.sizeBytes,
      modifiedAt: fullFile.modifiedAt,
      message: fullFile.message,
      openingTreeIndex: fullFile.openingTreeIndex,
      pgnOffsetIndex: fullFile.pgnOffsetIndex,
      rawPgnCatalog: descriptor,
      contentFingerprint: fingerprint,
      isWritableEmptyDatabase: fullFile.isWritableEmptyDatabase,
      gameCount: fullFile.gameCount,
    );
    final source = LocalChessSource(
      id: fullSource.id,
      label: fullSource.label,
      paths: fullSource.paths,
      rootPath: fullSource.rootPath,
      scannedAt: fullSource.scannedAt,
      root: LocalChessFolderNode.fromChildren(
        name: fullSource.root.name,
        path: fullSource.root.path,
        relativePath: fullSource.root.relativePath,
        children: <LocalChessNode>[node],
        scanError: fullSource.root.scanError,
      ),
    );
    send.send(
      _RawPgnCatalogReady(
        requestPort: requests.sendPort,
        descriptor: descriptor,
        source: source,
      ),
    );
    final projectionCache = _RawCatalogProjectionCache(games);
    requests.listen((message) async {
      if (message is _RawPgnCatalogClose) Isolate.exit();
      final envelope = message as List;
      final id = envelope[0] as int;
      final payload = envelope[1];
      try {
        if (payload is _RawPgnCatalogValidate) {
          if (request.debugValidationDelay != null) {
            await Future<void>.delayed(request.debugValidationDelay!);
          }
          send.send([
            id,
            'fresh',
            await _rawCatalogDescriptorIsFresh(
              descriptor,
              expectedFullSha256: fullSha256,
              strongValidation: payload.strong,
            ),
          ]);
          return;
        }
        final query = payload as LocalRawPgnCatalogPageQuery;
        if (!await _rawCatalogDescriptorIsFresh(query.descriptor)) {
          send.send([id, 'stale']);
        } else {
          send.send([id, 'ok', projectionCache.page(query)]);
        }
      } on StateError catch (error) {
        send.send([id, 'state', error.message]);
      } catch (error, stack) {
        send.send([id, 'other', error.toString(), stack.toString()]);
      }
    });
  } catch (error) {
    send.send(_RawPgnCatalogFailure(error));
  }
}

Future<bool> _rawCatalogDescriptorIsFresh(
  LocalRawPgnCatalogDescriptor descriptor, {
  String? expectedFullSha256,
  bool strongValidation = false,
}) async {
  final stat = await File(descriptor.path).stat();
  if (stat.size != descriptor.fileSizeBytes ||
      stat.modified != descriptor.modifiedAt) {
    return false;
  }
  final fingerprint = await computeLocalChessFileContentFingerprint(
    descriptor.path,
    stat: stat,
  );
  if (fingerprint != descriptor.contentFingerprint) return false;
  if (!strongValidation) return true;
  final expected = expectedFullSha256 ?? descriptor.fullSha256;
  if (expected.isEmpty) return false;
  return await _computeStableRawPgnCatalogFullSha256(
        descriptor.path,
        expectedStat: stat,
      ) ==
      expected;
}

Future<String> _computeRawPgnCatalogFullSha256(String path) async {
  return (await sha256.bind(File(path).openRead()).first).toString();
}

Future<String> _computeStableRawPgnCatalogFullSha256(
  String path, {
  required FileStat expectedStat,
}) async {
  final value = await _computeRawPgnCatalogFullSha256(path);
  final afterHash = await File(path).stat();
  if (afterHash.size != expectedStat.size ||
      afterHash.modified != expectedStat.modified) {
    throw StateError('The PGN file changed while its catalog was opening.');
  }
  return value;
}

class _RawCatalogProjectionCache {
  _RawCatalogProjectionCache(this.games);

  final List<LocalChessGame> games;
  final _projections = <String, List<LocalChessGame>>{};

  LocalChessGameQueryPage page(LocalRawPgnCatalogPageQuery query) {
    final key = _projectionKey(query);
    final projection = _projections.putIfAbsent(
      key,
      () => _rawCatalogProjection(games, query),
    );
    while (_projections.length > 4) {
      _projections.remove(_projections.keys.first);
    }
    final size = query.pageSize <= 0 ? 100 : query.pageSize.clamp(1, 200);
    final page = query.pageNumber < 0 ? 0 : query.pageNumber;
    final start = page * size;
    final end = (start + size).clamp(0, projection.length);
    return LocalChessGameQueryPage(
      games:
          start >= projection.length
              ? const <LocalChessGame>[]
              : projection.sublist(start, end),
      totalCount: projection.length,
      pageNumber: page,
      pageSize: size,
    );
  }
}

List<LocalChessGame> _rawCatalogProjection(
  List<LocalChessGame> games,
  LocalRawPgnCatalogPageQuery query,
) {
  Iterable<LocalChessGame> rows = games;
  final search = query.search.trim().toLowerCase();
  if (search.isNotEmpty) {
    rows = rows.where((game) => _rawCatalogMatchesSearch(game, search));
  }
  final filter = query.filter;
  if (filter != null && filter.hasActiveFilters) {
    rows = rows.where(
      (game) => localChessGameMatchesFilter(
        game,
        filter,
        playerFideId: query.playerFideId,
        playerAliases: query.playerAliases,
      ),
    );
  }
  final sorted = rows.toList(growable: false);
  sorted.sort(
    (a, b) => _compareRawCatalogGames(a, b, query.sortBy, query.sortDirection),
  );
  return sorted;
}

String _projectionKey(LocalRawPgnCatalogPageQuery query) {
  final filter = query.filter;
  final f = filter?.base;
  return [
    query.search.trim().toLowerCase(),
    query.sortBy.name,
    query.sortDirection.name,
    query.playerFideId ?? '',
    ...query.playerAliases.map((alias) => alias.trim().toLowerCase()),
    filter?.playerOutcome.name ?? '',
    filter?.opponentName ?? '',
    filter?.timeControlCategory ?? '',
    f?.result.name ?? '',
    f?.finish.name ?? '',
    f?.color.name ?? '',
    f?.timeControl.name ?? '',
    f?.online.name ?? '',
    f?.live.name ?? '',
    f?.eco.code ?? '',
    f?.minYear.toString() ?? '',
    f?.maxYear.toString() ?? '',
    f?.minRating.toString() ?? '',
    f?.maxRating.toString() ?? '',
  ].join('\u{1f}');
}

bool _rawCatalogMatchesSearch(LocalChessGame game, String query) {
  final terms = query.split(RegExp(r'\s+')).where((term) => term.isNotEmpty);
  for (final term in terms) {
    if (!_rawCatalogMatchesSearchTerm(game, term)) return false;
  }
  return true;
}

bool _rawCatalogMatchesSearchTerm(LocalChessGame game, String term) {
  if (game.fileName.toLowerCase().contains(term)) return true;
  if (game.sourceRelativePath.toLowerCase().contains(term)) return true;
  for (final value in game.game.metadata.values) {
    if (value is String && value.toLowerCase().contains(term)) return true;
  }
  return false;
}

int _compareRawCatalogGames(
  LocalChessGame a,
  LocalChessGame b,
  LocalChessGameSortField sortBy,
  LocalChessGameSortDirection direction,
) {
  final amd = a.game.metadata;
  final bmd = b.game.metadata;
  final primary = switch (sortBy) {
    LocalChessGameSortField.originalOrder => a.indexInFile.compareTo(
      b.indexInFile,
    ),
    LocalChessGameSortField.white => _compareRawCatalogText(
      localPgnDisplayPlayerName(amd, 'White'),
      localPgnDisplayPlayerName(bmd, 'White'),
    ),
    LocalChessGameSortField.whiteElo => _compareRawCatalogInt(
      _rawRating(amd, 'WhiteElo'),
      _rawRating(bmd, 'WhiteElo'),
    ),
    LocalChessGameSortField.black => _compareRawCatalogText(
      localPgnDisplayPlayerName(amd, 'Black'),
      localPgnDisplayPlayerName(bmd, 'Black'),
    ),
    LocalChessGameSortField.blackElo => _compareRawCatalogInt(
      _rawRating(amd, 'BlackElo'),
      _rawRating(bmd, 'BlackElo'),
    ),
    LocalChessGameSortField.result => _compareRawCatalogText(
      _rawMeta(amd, 'Result'),
      _rawMeta(bmd, 'Result'),
    ),
    LocalChessGameSortField.eco => _compareRawCatalogText(
      _rawMeta(amd, 'ECO'),
      _rawMeta(bmd, 'ECO'),
    ),
    LocalChessGameSortField.opening => _compareRawCatalogText(
      _rawOpening(amd),
      _rawOpening(bmd),
    ),
    LocalChessGameSortField.event => _compareRawCatalogText(
      _rawMeta(amd, 'Event'),
      _rawMeta(bmd, 'Event'),
    ),
    LocalChessGameSortField.date => _compareRawCatalogText(
      _rawMeta(amd, 'Date'),
      _rawMeta(bmd, 'Date'),
    ),
  };
  final directed =
      direction == LocalChessGameSortDirection.asc ? primary : -primary;
  return directed == 0 ? a.indexInFile.compareTo(b.indexInFile) : directed;
}

int _compareRawCatalogInt(int? a, int? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

int _compareRawCatalogText(String a, String b) {
  final left = a.trim();
  final right = b.trim();
  final leftMissing = left.isEmpty || left == '?' || left == '-';
  final rightMissing = right.isEmpty || right == '?' || right == '-';
  if (leftMissing && rightMissing) return 0;
  if (leftMissing) return 1;
  if (rightMissing) return -1;
  return left.toLowerCase().compareTo(right.toLowerCase());
}

String _rawMeta(Map<String, dynamic> metadata, String key) =>
    metadata[key]?.toString().trim() ?? '';

String _rawOpening(Map<String, dynamic> metadata) {
  final opening = _rawMeta(metadata, 'Opening');
  return opening.isNotEmpty ? opening : _rawMeta(metadata, 'ECO');
}

int? _rawRating(Map<String, dynamic> metadata, String key) {
  final value = int.tryParse(_rawMeta(metadata, key));
  return value == null || value <= 0 ? null : value;
}

String _catalogSessionId(
  String path,
  FileStat stat,
  String fingerprint,
  String fullSha256,
) {
  return sha256
      .convert(
        '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}|$fingerprint|$fullSha256'
            .codeUnits,
      )
      .toString();
}
