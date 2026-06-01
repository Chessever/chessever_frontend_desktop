import 'dart:io';

import 'package:chessever/desktop/services/desktop_update_recovery_marker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopUpdateRecoveryMarkerStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('desktop_update_marker_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('persists and clears an install marker', () async {
      final store = DesktopUpdateRecoveryMarkerStore(baseDirectory: tempDir);
      final marker = DesktopUpdateInstallMarker(
        platform: 'macos',
        fromVersion: '3.9.9+79',
        targetVersion: '4.0.0+80',
        stagingPath: '/tmp/stage',
        createdAt: DateTime.utc(2026, 5, 22),
      );

      await store.write(marker);
      final loaded = await store.read();

      expect(loaded, isNotNull);
      expect(loaded!.platform, 'macos');
      expect(loaded.fromVersion, '3.9.9+79');
      expect(loaded.targetVersion, '4.0.0+80');
      expect(loaded.stagingPath, '/tmp/stage');
      expect(loaded.isSatisfiedBy('3.9.9+79'), isFalse);
      expect(loaded.isSatisfiedBy('4.0.0+80'), isTrue);

      await store.clear();
      expect(await store.read(), isNull);
    });

    test('drops malformed marker files', () async {
      final store = DesktopUpdateRecoveryMarkerStore(baseDirectory: tempDir);
      await File(
        '${tempDir.path}/desktop_update_install_marker.json',
      ).writeAsString('{bad json');

      expect(await store.read(), isNull);
      expect(
        await File(
          '${tempDir.path}/desktop_update_install_marker.json',
        ).exists(),
        isFalse,
      );
    });

    test('persists a completed staged download marker', () async {
      final store = DesktopUpdateStagedDownloadMarkerStore(
        baseDirectory: tempDir,
      );
      final stage =
          await Directory(
            '${tempDir.path}/desktop_updater_stage_ready',
          ).create();
      await File('${stage.path}/MacOS/app').create(recursive: true);
      final marker = DesktopUpdateStagedDownloadMarker(
        platform: 'macos',
        fromVersion: '8.0.0+82',
        targetVersion: '8.0.1+83',
        stagingPath: stage.path,
        removedFiles: const ['old.file'],
        releaseNotes: 'Fix update handoff',
        createdAt: DateTime.utc(2026, 5, 23),
      );

      await store.write(marker);
      final loaded = await store.read();

      expect(loaded, isNotNull);
      expect(loaded!.platform, 'macos');
      expect(loaded.targetVersion, '8.0.1+83');
      expect(loaded.removedFiles, ['old.file']);
      expect(loaded.releaseNotes, 'Fix update handoff');
      expect(loaded.isSatisfiedBy('8.0.0+82'), isFalse);
      expect(loaded.isSatisfiedBy('8.0.1+83'), isTrue);
      expect(await loaded.hasCompleteStagingDirectory(), isTrue);
    });

    test('rejects staged downloads that still contain partial files', () async {
      final stage =
          await Directory(
            '${tempDir.path}/desktop_updater_stage_partial',
          ).create();
      await File('${stage.path}/MacOS/app.part').create(recursive: true);
      final marker = DesktopUpdateStagedDownloadMarker(
        platform: 'macos',
        fromVersion: '8.0.0+82',
        targetVersion: '8.0.1+83',
        stagingPath: stage.path,
        removedFiles: const [],
        releaseNotes: '',
        createdAt: DateTime.utc(2026, 5, 23),
      );

      expect(await marker.hasCompleteStagingDirectory(), isFalse);
    });

    test(
      'cleans orphaned stage directories but keeps the active one',
      () async {
        final cleaner = DesktopUpdateStageDirectoryCleaner(
          tempDirectory: tempDir,
        );
        final orphan =
            await Directory(
              '${tempDir.path}/desktop_updater_stage_orphan',
            ).create();
        await File('${orphan.path}/Info.plist').writeAsString('plist');
        final active =
            await Directory(
              '${tempDir.path}/desktop_updater_stage_active',
            ).create();
        await File('${active.path}/Info.plist').writeAsString('plist');

        await cleaner.deleteOrphaned(
          keepPath: active.path,
          minimumAge: Duration.zero,
        );

        expect(await orphan.exists(), isFalse);
        expect(await active.exists(), isTrue);
      },
    );
  });
}
