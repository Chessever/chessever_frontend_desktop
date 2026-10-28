import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Path the web build's engine installer reports for Stockfish. There is no
/// file: [startWebEngineProcess] maps it to the Web Worker script.
const String kWebStockfishEnginePath = 'web-worker:stockfish';

const String _stockfishWorkerUrl = 'stockfish/stockfish-19-lite-single.js';

/// Starts a UCI engine in a Web Worker behind dart:io's [Process] interface,
/// so `UciEngine` drives it exactly like a desktop subprocess: UCI lines in
/// on stdin, lines out on stdout, `kill` terminates the worker.
Future<Process> startWebEngineProcess(String enginePath) async {
  if (enginePath != kWebStockfishEnginePath) {
    throw ProcessException(enginePath, const [], 'No web engine at this path');
  }
  return _WorkerProcess(web.Worker(_stockfishWorkerUrl.toJS));
}

class _WorkerProcess implements Process {
  _WorkerProcess(this._worker) {
    _worker.onmessage =
        ((web.MessageEvent event) {
          final data = event.data;
          if (data == null || !data.isA<JSString>()) return;
          if (!_stdout.isClosed) {
            _stdout.add(utf8.encode('${(data as JSString).toDart}\n'));
          }
        }).toJS;
    _worker.onerror = ((web.Event _) => _exit(1)).toJS;
  }

  final web.Worker _worker;
  final StreamController<List<int>> _stdout = StreamController();
  final StreamController<List<int>> _stderr = StreamController();
  final Completer<int> _exitCode = Completer<int>();
  late final IOSink _stdin = _WorkerSink(this);

  void _post(String line) {
    if (_exitCode.isCompleted) return;
    _worker.postMessage(line.toJS);
    if (line.trim() == 'quit') _exit(0);
  }

  void _exit(int code) {
    if (_exitCode.isCompleted) return;
    _worker.terminate();
    _exitCode.complete(code);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 0;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _exit(-1);
    return true;
  }
}

/// Line-oriented stdin: each written line becomes one worker message.
class _WorkerSink implements IOSink {
  _WorkerSink(this._process);

  final _WorkerProcess _process;
  final StringBuffer _pending = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? object) {
    _pending.write(object);
    _drainLines();
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void add(List<int> data) => write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (_pending.isNotEmpty) {
      _process._post(_pending.toString());
      _pending.clear();
    }
  }

  @override
  Future<void> get done => _process.exitCode;

  void _drainLines() {
    final text = _pending.toString();
    final end = text.lastIndexOf('\n');
    if (end < 0) return;
    for (final line in text.substring(0, end).split('\n')) {
      if (line.isNotEmpty) _process._post(line);
    }
    _pending
      ..clear()
      ..write(text.substring(end + 1));
  }
}
