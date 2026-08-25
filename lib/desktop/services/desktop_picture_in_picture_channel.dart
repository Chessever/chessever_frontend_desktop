import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const _pictureInPictureChannel = WindowMethodChannel(
  'chessever/picture_in_picture',
  mode: ChannelMode.unidirectional,
);

const String _restoreMainWindowMethod = 'restoreMainWindow';
const String _pictureInPictureDismissedMethod = 'pictureInPictureDismissed';
const String _pictureInPictureGameChangedMethod = 'pictureInPictureGameChanged';
const String _replacePictureInPictureGameMethod = 'replacePictureInPictureGame';

/// Registers the single receiver owned by the primary desktop engine.
Future<void> registerPictureInPictureMainWindowHandler({
  Future<void> Function(String encodedBoardPayload)? onRestoreBoard,
  Future<void> Function()? onPictureInPictureDismissed,
  Future<void> Function(String gameId)? onPictureInPictureGameChanged,
}) {
  return _pictureInPictureChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case _pictureInPictureDismissedMethod:
        await onPictureInPictureDismissed?.call();
        return true;
      case _pictureInPictureGameChangedMethod:
        final gameId = call.arguments?.toString().trim() ?? '';
        if (gameId.isNotEmpty) {
          await onPictureInPictureGameChanged?.call(gameId);
        }
        return true;
      case _restoreMainWindowMethod:
        final encodedBoardPayload = call.arguments;
        if (onRestoreBoard != null && encodedBoardPayload is String) {
          await onRestoreBoard(encodedBoardPayload);
        }
        await onPictureInPictureDismissed?.call();
        if (await windowManager.isMinimized()) {
          await windowManager.restore();
        }
        await windowManager.show();
        await windowManager.focus();
        return true;
      default:
        throw MissingPluginException('Unknown PiP method: ${call.method}');
    }
  });
}

/// Registers the receiver owned by the one reusable PiP child engine.
Future<void> registerPictureInPictureWindowHandler({
  required WindowController controller,
  required Future<void> Function(String encodedBoardPayload) onReplaceBoard,
}) {
  return controller.setWindowMethodHandler((call) async {
    if (call.method != _replacePictureInPictureGameMethod) {
      throw MissingPluginException('Unknown PiP window method: ${call.method}');
    }
    final encodedBoardPayload = call.arguments;
    if (encodedBoardPayload is! String) {
      throw const FormatException('PiP replacement payload must be a string');
    }
    await onReplaceBoard(encodedBoardPayload);
    return true;
  });
}

Future<bool> replacePictureInPictureGame({
  required WindowController controller,
  required String encodedBoardPayload,
}) async {
  final replaced = await controller.invokeMethod<bool>(
    _replacePictureInPictureGameMethod,
    encodedBoardPayload,
  );
  return replaced == true;
}

/// Visually dismisses only the current PiP child. The reusable engine stays
/// alive so every later PiP request can replace it instead of spawning a
/// second window. Crucially, this never calls the process-wide window close
/// path used by the primary app.
Future<void> dismissCurrentPictureInPictureWindow({
  bool notifyMainWindow = true,
}) async {
  final controller = await WindowController.fromCurrentEngine();
  await controller.hide();
  if (notifyMainWindow) {
    await _pictureInPictureChannel.invokeMethod<bool>(
      _pictureInPictureDismissedMethod,
    );
  }
}

Future<void> notifyPictureInPictureGameChanged(String gameId) async {
  final normalized = gameId.trim();
  if (normalized.isEmpty) return;
  await _pictureInPictureChannel.invokeMethod<bool>(
    _pictureInPictureGameChangedMethod,
    normalized,
  );
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
