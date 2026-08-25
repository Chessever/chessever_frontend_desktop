import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const _pictureInPictureChannel = WindowMethodChannel(
  'chessever/picture_in_picture',
  mode: ChannelMode.unidirectional,
);

const String _restoreMainWindowMethod = 'restoreMainWindow';

/// Registers the single receiver owned by the primary desktop engine.
Future<void> registerPictureInPictureMainWindowHandler({
  Future<void> Function(String encodedBoardPayload)? onRestoreBoard,
}) {
  return _pictureInPictureChannel.setMethodCallHandler((call) async {
    if (call.method != _restoreMainWindowMethod) {
      throw MissingPluginException('Unknown PiP method: ${call.method}');
    }

    final encodedBoardPayload = call.arguments;
    if (onRestoreBoard != null && encodedBoardPayload is String) {
      await onRestoreBoard(encodedBoardPayload);
    }
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
    return true;
  });
}

/// Brings the existing primary window forward from a secondary PiP engine.
Future<bool> restoreMainWindowFromPictureInPicture({
  required String encodedBoardPayload,
}) async {
  final restored = await _pictureInPictureChannel.invokeMethod<bool>(
    _restoreMainWindowMethod,
    encodedBoardPayload,
  );
  return restored == true;
}
