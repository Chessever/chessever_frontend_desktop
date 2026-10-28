import 'dart:convert';

import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tab_kind_restore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('restoreTabKindByName', () {
    test('keeps surviving kinds as themselves', () {
      for (final kind in TabKind.values) {
        final restored = restoreTabKindByName(kind.name);
        expect(restored.kind, kind);
        expect(restored.retired, isFalse);
      }
    });

    test('redirects the retired notification settings tab to Settings', () {
      expect(TabKind.values.map((kind) => kind.name),
          isNot(contains('notificationSettings')));
      final restored = restoreTabKindByName('notificationSettings');
      expect(restored.kind, TabKind.settings);
      expect(restored.retired, isTrue);
    });

    test('unknown or missing names fall back without throwing', () {
      expect(restoreTabKindByName('noSuchKind').kind, TabKind.board);
      expect(restoreTabKindByName(null).kind, TabKind.board);
      expect(restoreTabKindByName(42).kind, TabKind.board);
    });
  });

  test('a persisted notificationSettings tab window restores as Settings', () {
    final payload = DesktopBoardWindowPayload.decode(
      jsonEncode({
        'type': desktopTabWindowPayloadType,
        'kind': 'notificationSettings',
        'title': 'Notifications',
      }),
    );
    expect(payload.kind, TabKind.settings);
    // The stale title described the removed pane, not Settings.
    expect(payload.title, TabKind.settings.defaultTitle);
  });
}
