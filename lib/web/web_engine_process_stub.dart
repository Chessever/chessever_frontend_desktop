import 'dart:io';

/// Native builds start real engine binaries; see web_engine_process.dart.
const String kWebStockfishEnginePath = 'web-worker:stockfish';

Future<Process> startWebEngineProcess(String enginePath) =>
    throw UnsupportedError('Web engines run only in the browser build.');
