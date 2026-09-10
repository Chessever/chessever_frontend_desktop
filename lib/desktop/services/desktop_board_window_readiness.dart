import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

const desktopBoardReadyMethod = 'detachedBoardReady';

/// Native show completion is not evidence that the child restored its board.
class DetachedBoardWindow {
  const DetachedBoardWindow({required this.windowId, required this.probe});

  final String windowId;
  final Future<Object?> Function(String transferId) probe;

  factory DetachedBoardWindow.fromController(WindowController controller) {
    return DetachedBoardWindow(
      windowId: controller.windowId,
      probe:
          (transferId) => controller.invokeMethod<Object?>(
            desktopBoardReadyMethod,
            transferId,
          ),
    );
  }

  Future<void> waitUntilReady(
    String transferId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      try {
        final reply = await probe(transferId).timeout(timeout - clock.elapsed);
        if (reply is Map &&
            reply['windowId'] == windowId &&
            reply['transferId'] == transferId &&
            reply['ready'] == true) {
          return;
        }
      } on TimeoutException {
        rethrow;
      } on MissingPluginException {
        // The child's independent engine has not registered its receiver yet.
      } on PlatformException {
        // Channel registration can lag native creation, or the child can die.
      }
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < const Duration(milliseconds: 100)
            ? remaining
            : const Duration(milliseconds: 100),
      );
    }
    throw TimeoutException('Detached board did not restore in time', timeout);
  }
}

/// Install only after successful working-tree AND save-origin restoration.
Future<void> registerDetachedBoardReadyHandler({
  required WindowController controller,
  required String transferId,
}) {
  return controller.setWindowMethodHandler((call) async {
    if (call.method != desktopBoardReadyMethod) {
      throw MissingPluginException('Unknown detached board method');
    }
    return {
      'windowId': controller.windowId,
      'transferId': transferId,
      'ready': call.arguments == transferId,
    };
  });
}
