import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/local_chess_file_access.dart';
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
    if (!kReleaseMode) return false;
    if (initialArguments.contains(_newInstanceFlag)) return false;

    final paths = await chessPathsFromArguments(initialArguments);
    if (paths.isEmpty) {
      await _startSingleInstanceServer();
      return false;
    }

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
        _emitForwardedPaths(await chessPathsFromSingleInstancePayload(payload));
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
    final initialPaths = await chessPathsFromArguments(initialArguments);
    if (_started) return _dedupePaths(initialPaths);
    _started = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'openFiles':
          final paths = await chessPathsFromPlatformPayload(call.arguments);
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
          ...await chessPathsFromPlatformPayload(pending),
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
  static Future<bool> hasForwardableSingleInstancePayload(
    Iterable<String> initialArguments,
  ) async {
    return (await chessPathsFromArguments(initialArguments)).isNotEmpty;
  }

  @visibleForTesting
  static String singleInstancePayloadForPaths(List<String> paths) {
    return '${jsonEncode(<String, Object>{'paths': paths})}\n';
  }

  @visibleForTesting
  static Future<List<String>> chessPathsFromSingleInstancePayload(
    String payload,
  ) async {
    try {
      final decoded = jsonDecode(payload.trim());
      if (decoded is Map<String, Object?>) {
        return await chessPathsFromPlatformPayload(decoded['paths']);
      }
    } on Object {
      return const <String>[];
    }
    return const <String>[];
  }

  static Future<List<String>> chessPathsFromPlatformPayload(
    Object? payload,
  ) async {
    if (payload is! Iterable) return const <String>[];
    return chessPathsFromArguments(payload.whereType<String>());
  }

  static Future<List<String>> chessPathsFromArguments(
    Iterable<String> arguments,
  ) async {
    final paths = <String>[];
    for (final argument in arguments) {
      final path = await _pathFromArgument(argument);
      if (path != null) paths.add(path);
    }
    return _dedupePaths(paths);
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

  static Future<String?> _pathFromArgument(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('--')) return null;

    final maybeUri = Uri.tryParse(trimmed);
    final isWindowsDrivePath = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed);
    if (maybeUri != null &&
        maybeUri.hasScheme &&
        maybeUri.scheme != 'file' &&
        !isWindowsDrivePath) {
      return null;
    }
    final path =
        maybeUri != null && maybeUri.scheme == 'file'
            ? maybeUri.toFilePath(windows: Platform.isWindows)
            : trimmed;

    // Recognized files go through the import worker even when missing or
    // locked so the user receives its actionable error instead of a silent
    // startup drop. Only directory detection needs an external-path probe.
    if (looksLikeLocalChessFile(path)) return path;
    try {
      final probe = await probeLocalChessPathInWorker(path);
      if (probe.isDirectory) return path;
    } on LocalChessFileAccessException {
      // Let the normal library intake flow report unavailable drives/shares;
      // startup itself must remain able to render.
      return path;
    }

    return null;
  }
}
