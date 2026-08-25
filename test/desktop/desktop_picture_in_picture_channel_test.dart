import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_picture_in_picture_channel.dart';

void main() {
  test(
    'PiP dismissal deactivates main without restoring or focusing it',
    () async {
      final trace = <String>[];
      final controller = _RecordingMainWindowController(trace: trace);

      final handled = await handlePictureInPictureMainWindowMethod(
        call: const MethodCall('pictureInPictureDismissed'),
        windowController: controller,
        onPictureInPictureDismissed: () async => trace.add('dismissed'),
      );

      expect(handled, isTrue);
      expect(trace, const ['dismissed', 'blur']);
      expect(trace.where(const {'restore', 'show', 'focus'}.contains), isEmpty);
    },
  );

  test('fullscreen restoration is the only path that surfaces main', () async {
    final trace = <String>[];
    final controller = _RecordingMainWindowController(
      trace: trace,
      minimized: true,
    );

    final handled = await handlePictureInPictureMainWindowMethod(
      call: const MethodCall('restoreMainWindow', 'encoded-board'),
      windowController: controller,
      onRestoreBoard: (payload) async => trace.add('board:$payload'),
      onPictureInPictureDismissed: () async => trace.add('dismissed'),
    );

    expect(handled, isTrue);
    expect(trace, const [
      'board:encoded-board',
      'dismissed',
      'isMinimized',
      'restore',
      'show',
      'focus',
    ]);
    expect(trace, isNot(contains('blur')));
  });
}

class _RecordingMainWindowController
    implements PictureInPictureMainWindowController {
  _RecordingMainWindowController({required this.trace, this.minimized = false});

  final List<String> trace;
  final bool minimized;

  @override
  Future<void> blur() async => trace.add('blur');

  @override
  Future<void> focus() async => trace.add('focus');

  @override
  Future<bool> isMinimized() async {
    trace.add('isMinimized');
    return minimized;
  }

  @override
  Future<void> restore() async => trace.add('restore');

  @override
  Future<void> show() async => trace.add('show');
}
