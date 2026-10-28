import 'dart:io';

import 'package:chessever/desktop/services/desktop_push_isolation.dart';
import 'package:chessever/providers/notifications_settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Transitive `import`/`export`/`part` closure of [entries] inside `lib/`.
Set<String> _libraryClosure(List<String> entries) {
  final directive = RegExp(
    r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  final seen = <String>{};
  final pending = [...entries];
  while (pending.isNotEmpty) {
    final path = File(pending.removeLast()).absolute.path;
    if (!seen.add(path) || !File(path).existsSync()) continue;
    for (final match in directive.allMatches(File(path).readAsStringSync())) {
      final uri = match.group(1)!;
      if (uri.startsWith('dart:')) continue;
      String? resolved;
      if (uri.startsWith('package:chessever/')) {
        resolved = 'lib/${uri.substring('package:chessever/'.length)}';
      } else if (!uri.startsWith('package:')) {
        resolved = File(path).parent.uri.resolve(uri).toFilePath();
      }
      if (resolved != null) pending.add(File(resolved).absolute.path);
    }
  }
  return seen;
}

String _relative(String absolute) {
  final root = '${Directory.current.absolute.path}${Platform.pathSeparator}';
  return absolute.startsWith(root)
      ? absolute.substring(root.length).replaceAll(r'\', '/')
      : absolute;
}

void main() {
  group('desktop never builds the push-writing notifier', () {
    test('the override resolves to an inert notifier that never forwards', () async {
      final container = ProviderContainer(
        overrides: desktopPushIsolationOverrides,
      );
      addTearDown(container.dispose);

      final notifier = container.read(notificationsSettingsProvider.notifier);
      expect(notifier, isA<DesktopInertNotificationsSettingsNotifier>());
      expect(container.read(notificationsSettingsProvider).enabled, isFalse);

      await notifier.setEnabled(true);
      expect(container.read(notificationsSettingsProvider).enabled, isFalse);
      await notifier.setEnabled(false);
      expect(container.read(notificationsSettingsProvider).enabled, isFalse);
    });

    test('every desktop root container installs the isolation override', () {
      final rootContainers = <String, int>{};
      for (final entity in Directory('lib/desktop').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final count = RegExp(
          r'\bProviderContainer\(',
        ).allMatches(entity.readAsStringSync()).length;
        if (count > 0) rootContainers[_relative(entity.path)] = count;
      }
      // The only root containers desktop creates live in desktop_main.dart.
      expect(rootContainers.keys, ['lib/desktop/desktop_main.dart']);

      final main = File('lib/desktop/desktop_main.dart').readAsStringSync();
      expect(
        RegExp(r'\.\.\.desktopPushIsolationOverrides').allMatches(main).length,
        rootContainers['lib/desktop/desktop_main.dart'],
        reason: 'each ProviderContainer in desktop_main must spread the '
            'push isolation overrides',
      );
    });

    test('the only push_enabled writes are unreachable except through the '
        'overridden provider', () {
      final closure = _libraryClosure([
        'lib/desktop/desktop_main.dart',
        'lib/main.dart',
      ]).map(_relative).toSet();
      expect(closure, contains('lib/desktop/desktop_main.dart'));

      final writes = <String>{};
      final serviceCallers = <String>{};
      final desktopProviderReaders = <String>{};
      for (final path in closure) {
        final source = File(path).readAsStringSync();
        // Real write shapes only: a `push_enabled` map key or a query on the
        // preferences table. Doc comments that name the column do not count.
        if (source.contains("'push_enabled':") ||
            source.contains("from('user_notification_preferences')")) {
          writes.add(path);
        }
        if (source.contains('PushNotificationsService.instance')) {
          serviceCallers.add(path);
        }
        if (path.startsWith('lib/desktop/') &&
            (source.contains('notificationsSettingsProvider') ||
                source.contains('PushNotificationsService'))) {
          desktopProviderReaders.add(path);
        }
      }

      // Both Supabase writes live in the shared service ...
      expect(writes, {'lib/services/push_notifications_service.dart'});
      // ... which is only driven by the shared notifier ...
      expect(serviceCallers, {
        'lib/providers/notifications_settings_provider.dart',
      });
      // ... which desktop code only touches to replace it.
      expect(desktopProviderReaders, {
        'lib/desktop/services/desktop_push_isolation.dart',
      });
      expect(
        closure,
        isNot(contains('lib/desktop/panes/notification_settings_pane.dart')),
      );
    });
  });
}
