import 'dart:async';

import 'package:flutter/foundation.dart';

class OperationCanceledException implements Exception {
  const OperationCanceledException([this.message = 'Operation was canceled.']);

  final String message;

  @override
  String toString() => message;
}

bool isOperationCanceled(Object error) =>
    error is OperationCanceledException ||
    error.toString().toLowerCase().contains('operation was canceled');

class OperationCancellationToken {
  final _canceled = Completer<void>();
  final _listeners = <VoidCallback>{};

  bool get isCanceled => _canceled.isCompleted;
  Future<void> get whenCanceled => _canceled.future;

  void cancel() {
    if (_canceled.isCompleted) return;
    _canceled.complete();
    final listeners = List<VoidCallback>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  VoidCallback addListener(VoidCallback listener) {
    if (_canceled.isCompleted) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void throwIfCanceled() {
    if (isCanceled) throw const OperationCanceledException();
  }
}
