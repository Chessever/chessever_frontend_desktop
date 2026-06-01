import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

class DesktopFileOpenService {
  DesktopFileOpenService._();

  static final DesktopFileOpenService instance = DesktopFileOpenService._();
  static const MethodChannel _channel = MethodChannel(
    'chessever.desktop/file_open',
  );
  static const int _singleInstancePort = 47683;
  static const String _newInstanceFlag = '--new-instance';

  final _controller = StreamController<List<String>>.broadcast();
  final _pendingSingleInstancePaths = <String>[];
  bool _started = false;
  ServerSocket? _singleInstanceServer;

  Stream<List<String>> get openPaths => _controller.stream;

  Future<bool> forwardToPrimaryIfRunning({
    List<String> initialArguments = const <String>[],
  }) async {
    if (initialArguments.contains(_newInstanceFlag)) return false;

    final paths = chessPathsFromArguments(initialArguments);
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _singleInstancePort,
        timeout: const Duration(milliseconds: 250),
      );
      socket.write(singleInstancePayloadForPaths(paths));
      await socket.flush();
      await socket.close();
      return true;
    } on Object {
      await _startSingleInstanceServer();
      return false;
    }
  }

  Future<void> _startSingleInstanceServer() async {
    if (_singleInstanceServer != null) return;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _singleInstancePort,
        shared: false,
      );
      _singleInstanceServer = server;
      server.listen(_handleSingleInstanceClient);
    } on Object {
      // If another process owns the handoff port but did not accept the quick
      // probe above, keep booting rather than blocking ChessEver startup.
    }
  }

  void _handleSingleInstanceClient(Socket socket) {
    unawaited(() async {
      try {
        final payload = await utf8.decoder.bind(socket).join();
        _emitForwardedPaths(chessPathsFromSingleInstancePayload(payload));
      } finally {
        await socket.close();
      }
    }());
  }

  void _emitForwardedPaths(List<String> paths) {
    if (paths.isEmpty) return;
    if (_started && _controller.hasListener) {
      _controller.add(paths);
      return;
    }
    _pendingSingleInstancePaths.addAll(paths);
  }

  Future<List<String>> start({
    List<String> initialArguments = const <String>[],
  }) async {
    final initialPaths = chessPathsFromArguments(initialArguments);
    if (_started) return _dedupePaths(initialPaths);
    _started = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'openFiles':
          final paths = chessPathsFromPlatformPayload(call.arguments);
          if (paths.isNotEmpty) _controller.add(paths);
        default:
          throw MissingPluginException(
            'No handler for ${call.method} on chessever.desktop/file_open',
          );
      }
    });

    if (Platform.isMacOS) {
      try {
        final pending = await _channel.invokeMethod<List<dynamic>>(
          'takeInitialOpenFiles',
        );
        return _dedupePaths(<String>[
          ...initialPaths,
          ..._takePendingSingleInstancePaths(),
          ...chessPathsFromPlatformPayload(pending),
        ]);
      } on MissingPluginException {
        return _dedupePaths(<String>[
          ...initialPaths,
          ..._takePendingSingleInstancePaths(),
        ]);
      } catch (_) {
        return _dedupePaths(<String>[
          ...initialPaths,
          ..._takePendingSingleInstancePaths(),
        ]);
      }
    }

    return _dedupePaths(<String>[
      ...initialPaths,
      ..._takePendingSingleInstancePaths(),
    ]);
  }

  List<String> _takePendingSingleInstancePaths() {
    if (_pendingSingleInstancePaths.isEmpty) return const <String>[];
    final paths = List<String>.of(_pendingSingleInstancePaths);
    _pendingSingleInstancePaths.clear();
    return paths;
  }

  @visibleForTesting
  static String singleInstancePayloadForPaths(List<String> paths) {
    return '${jsonEncode(<String, Object>{'paths': paths})}\n';
  }

  @visibleForTesting
  static List<String> chessPathsFromSingleInstancePayload(String payload) {
    try {
      final decoded = jsonDecode(payload.trim());
      if (decoded is Map<String, Object?>) {
        return chessPathsFromPlatformPayload(decoded['paths']);
      }
    } on Object {
      return const <String>[];
    }
    return const <String>[];
  }

  static List<String> chessPathsFromPlatformPayload(Object? payload) {
    if (payload is! Iterable) return const <String>[];
    return chessPathsFromArguments(payload.whereType<String>());
  }

  static List<String> chessPathsFromArguments(Iterable<String> arguments) {
    return _dedupePaths(arguments.map(_pathFromArgument).whereType<String>());
  }

  static List<String> _dedupePaths(Iterable<String> paths) {
    final uniquePaths = <String>[];
    final seen = <String>{};

    for (final path in paths) {
      final key = localChessInputPathKey(path);
      if (!seen.add(key)) continue;
      uniquePaths.add(path);
    }

    return uniquePaths;
  }

  static String? _pathFromArgument(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('--')) return null;

    final maybeUri = Uri.tryParse(trimmed);
    final path = maybeUri != null && maybeUri.scheme == 'file'
        ? maybeUri.toFilePath(windows: Platform.isWindows)
        : trimmed;

    if (Directory(path).existsSync() ||
        (looksLikeLocalChessFile(path) && File(path).existsSync())) {
      return path;
    }

    return null;
  }
}
