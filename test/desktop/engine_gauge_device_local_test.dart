import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Desktop engine presentation preferences are device-local. The phone keeps
/// `showEngineGaugeOnBoard` / `showEngineGaugeInGrid` out of
/// `user_engine_settings` on purpose; desktop goes further and syncs none of
/// its engine settings. This pins that no Supabase write path exists, so a
/// gauge surface flag cannot reach the shared row from desktop.
void main() {
  test('the engine settings provider has no Supabase path', () {
    final source = File(
      'lib/providers/engine_settings_provider.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('user_engine_settings')));
    expect(source, isNot(contains('Supabase.instance')));
    expect(source, isNot(contains('supabase_flutter')));
    expect(source, isNot(contains('.upsert(')));
    expect(source, contains("'cached_engine_settings'"));
  });

  test('no desktop code writes engine settings to Supabase', () {
    final offenders = <String>[];
    for (final entity in Directory('lib/desktop').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains("from('user_engine_settings')") &&
          (source.contains('showEngineGauge') ||
              source.contains('show_engine_gauge'))) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
