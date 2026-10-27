import 'dart:async';
import 'dart:typed_data';

/// In-process stand-in for `dart:isolate` in the browser build, where
/// dart2wasm supports no isolates or ports. A spawned "isolate" runs its entry
/// point on this thread in its own zone; ports are message queues delivered
/// as events. Lifetime follows the real rules closely enough for the local
/// library workers: an isolate exits when its entry has returned and none of
/// its receive ports are open, or on [Isolate.kill], [Isolate.exit] or an
/// uncaught error (with `errorsAreFatal`), and then notifies `onExit`.

final Object _isolateKey = Object();

_EmulatedIsolate? get _currentEmulated =>
    Zone.current[_isolateKey] as _EmulatedIsolate?;

class SendPort {
  SendPort._(this._port);

  final ReceivePort _port;

  void send(Object? message) {
    final sender = _currentEmulated;
    if (sender != null && sender.exited) return;
    // Deliver as a separate event, like a real port.
    Timer.run(() => _port._deliver(message));
  }

  /// Runtime notices (exit, error) are sent on the isolate's behalf even
  /// after it has exited.
  void _notify(Object? message) => Timer.run(() => _port._deliver(message));

  @override
  bool operator ==(Object other) =>
      other is SendPort && identical(other._port, _port);

  @override
  int get hashCode => identityHashCode(_port);
}

class ReceivePort extends Stream<dynamic> {
  ReceivePort([String debugName = '']) : _owner = _currentEmulated {
    _owner?._openPorts++;
  }

  final _EmulatedIsolate? _owner;
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  bool _closed = false;
  late final SendPort sendPort = SendPort._(this);

  void _deliver(Object? message) {
    if (_closed || (_owner?.exited ?? false)) return;
    _controller.add(message);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_controller.close());
    final owner = _owner;
    if (owner != null) {
      owner._openPorts--;
      owner._maybeExit();
    }
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _controller.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class RawReceivePort {
  RawReceivePort([Function? handler, String debugName = ''])
    : _port = ReceivePort(debugName) {
    _subscription = _port.listen((message) => _handler?.call(message));
    _handler = handler;
  }

  final ReceivePort _port;
  late final StreamSubscription<dynamic> _subscription;
  Function? _handler;

  set handler(Function? value) => _handler = value;

  SendPort get sendPort => _port.sendPort;

  void close() {
    unawaited(_subscription.cancel());
    _port.close();
  }
}

class Capability {
  Capability();
}

class RemoteError implements Error {
  RemoteError(String errorDescription, String stackDescription)
    : _description = errorDescription,
      stackTrace = StackTrace.fromString(stackDescription);

  final String _description;

  @override
  final StackTrace stackTrace;

  @override
  String toString() => _description;
}

class IsolateSpawnException implements Exception {
  IsolateSpawnException(this.message);

  final String message;

  @override
  String toString() => 'IsolateSpawnException: $message';
}

abstract final class TransferableTypedData {
  factory TransferableTypedData.fromList(List<TypedData> list) =
      _TransferableTypedData;

  ByteBuffer materialize();
}

final class _TransferableTypedData implements TransferableTypedData {
  _TransferableTypedData(List<TypedData> list) {
    final builder = BytesBuilder(copy: true);
    for (final data in list) {
      builder.add(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    _bytes = Uint8List.fromList(builder.takeBytes());
  }

  late final Uint8List _bytes;

  @override
  ByteBuffer materialize() => _bytes.buffer;
}

class _IsolateExitSignal {
  const _IsolateExitSignal();
}

class _EmulatedIsolate {
  _EmulatedIsolate({this.errorsAreFatal = true});

  final bool errorsAreFatal;
  final List<(SendPort, Object?)> _exitListeners = [];
  final List<SendPort> _errorListeners = [];
  int _openPorts = 0;
  bool _entryReturned = false;
  bool exited = false;

  void _maybeExit() {
    if (_entryReturned && _openPorts <= 0) {
      // Let pending events (sends queued just before) land first.
      Timer.run(() {
        if (_openPorts <= 0) exit();
      });
    }
  }

  void exit() {
    if (exited) return;
    exited = true;
    for (final (port, response) in _exitListeners) {
      port._notify(response);
    }
  }

  void reportError(Object error, StackTrace stack) {
    for (final port in _errorListeners) {
      port._notify([error.toString(), stack.toString()]);
    }
    if (errorsAreFatal) exit();
  }
}

class Isolate {
  Isolate._(this._emulated);

  static const int immediate = 0;
  static const int beforeNextEvent = 1;

  final _EmulatedIsolate? _emulated;

  static final Isolate _main = Isolate._(null);

  static Isolate get current {
    final emulated = _currentEmulated;
    return emulated == null ? _main : Isolate._(emulated);
  }

  @override
  bool operator ==(Object other) =>
      other is Isolate && identical(other._emulated, _emulated);

  @override
  int get hashCode => identityHashCode(_emulated);

  static Future<R> run<R>(
    FutureOr<R> Function() computation, {
    String? debugName,
  }) async => await computation();

  static Future<Isolate> spawn<T>(
    void Function(T message) entryPoint,
    T message, {
    bool paused = false,
    bool errorsAreFatal = true,
    SendPort? onExit,
    SendPort? onError,
    String? debugName,
  }) async {
    final emulated = _EmulatedIsolate(errorsAreFatal: errorsAreFatal);
    if (onExit != null) emulated._exitListeners.add((onExit, null));
    if (onError != null) emulated._errorListeners.add(onError);
    final isolate = Isolate._(emulated);
    Timer.run(() {
      runZonedGuarded(
        () {
          Object? result;
          try {
            result = (entryPoint as dynamic)(message);
          } on _IsolateExitSignal {
            return;
          }
          if (result is Future) {
            result.whenComplete(() {
              emulated._entryReturned = true;
              emulated._maybeExit();
            });
          } else {
            emulated._entryReturned = true;
            emulated._maybeExit();
          }
        },
        (error, stack) {
          if (error is _IsolateExitSignal) return;
          emulated.reportError(error, stack);
        },
        zoneValues: {_isolateKey: emulated},
      );
    });
    return isolate;
  }

  /// Ends the current emulated isolate after sending [message] to
  /// [finalMessagePort].
  static Never exit([SendPort? finalMessagePort, Object? message]) {
    finalMessagePort?.send(message);
    _currentEmulated?.exit();
    throw const _IsolateExitSignal();
  }

  void kill({int priority = beforeNextEvent}) => _emulated?.exit();

  void addOnExitListener(SendPort responsePort, {Object? response}) {
    final emulated = _emulated;
    if (emulated == null) return;
    if (emulated.exited) {
      responsePort._notify(response);
    } else {
      emulated._exitListeners.add((responsePort, response));
    }
  }

  void removeOnExitListener(SendPort responsePort) =>
      _emulated?._exitListeners.removeWhere((l) => l.$1 == responsePort);

  void addErrorListener(SendPort port) => _emulated?._errorListeners.add(port);

  void removeErrorListener(SendPort port) =>
      _emulated?._errorListeners.remove(port);

  void setErrorsFatal(bool errorsAreFatal) {}
}
