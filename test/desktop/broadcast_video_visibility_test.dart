import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chessever/desktop/state/broadcast_video_visibility_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'event off survives a fresh container without hiding another event',
    () async {
      final first = ProviderContainer();
      final event = broadcastVideoVisibilityProvider('group:event-a');
      expect(await first.read(event.future), isTrue);
      await first.read(event.notifier).remember(false);
      first.dispose();

      final next = ProviderContainer();
      addTearDown(next.dispose);
      expect(await next.read(event.future), isFalse);
      expect(
        await next.read(
          broadcastVideoVisibilityProvider('group:event-b').future,
        ),
        isTrue,
      );
      await next.read(event.notifier).remember(true);
      expect(next.read(event).requireValue, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(BroadcastVideoVisibility.storageKey('group:event-a')),
        isTrue,
      );
    },
  );

  test('rapid hide/show/hide persists the last explicit choice', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final event = broadcastVideoVisibilityProvider('tour:a');
    await container.read(event.future);
    final notifier = container.read(event.notifier);
    await Future.wait([
      notifier.remember(false),
      notifier.remember(true),
      notifier.remember(false),
    ]);
    expect(container.read(event).requireValue, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(BroadcastVideoVisibility.storageKey('tour:a')),
      isFalse,
    );
  });

  test('toolbar retains camera and language selectors, not external icons', () {
    final source =
        File(
          'lib/desktop/widgets/broadcast_video_panel.dart',
        ).readAsStringSync();
    final toolbar = source.substring(
      source.indexOf('class _BroadcastVideoToolbar'),
      source.indexOf('class _LanguageGroupButton'),
    );
    expect(toolbar, isNot(contains('Icons.open_in_new_rounded')));
    expect(toolbar, isNot(contains('Icons.grid_view_rounded')));
    expect(toolbar, contains('Icons.videocam_rounded'));
    expect(
      toolbar,
      matches(
        RegExp(
          r'icon: visible\s*\? Icons\.videocam_off_rounded\s*: Icons\.videocam_rounded',
        ),
      ),
    );
    expect(toolbar, contains("tooltip: visible ? 'Hide video' : 'Show video'"));
    expect(toolbar, contains('_LanguageGroupButton('));
    expect(toolbar, contains('_OverflowLanguageButton('));
  });
}
