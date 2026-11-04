import 'dart:io';

import 'package:chessever/desktop/services/stale_native_asset_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The in-app updater removes a dropped framework's regular files but leaves
/// its directories and symlinks; this pins the startup cleanup that removes
/// that skeleton so updated installs match the release's code seal.
void main() {
  late Directory root;
  late String contents;
  late String frameworks;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('stale_native_assets_');
    contents = p.join(root.path, 'Chessever.app', 'Contents');
    frameworks = p.join(contents, 'Frameworks');
    Directory(frameworks).createSync(recursive: true);
  });

  tearDown(() async {
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['-R', 'u+w', root.path]);
    }
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// A versioned framework the way Flutter's native assets lay it out.
  void framework(String name, {bool withBinary = true}) {
    final dir = p.join(frameworks, '$name.framework');
    Directory(
      p.join(dir, 'Versions', 'A', 'Resources'),
    ).createSync(recursive: true);
    Directory(p.join(dir, 'Versions', 'A', '_CodeSignature')).createSync();
    if (withBinary) {
      File(p.join(dir, 'Versions', 'A', name)).writeAsBytesSync(<int>[1, 2]);
      File(
        p.join(dir, 'Versions', 'A', 'Resources', 'Info.plist'),
      ).writeAsStringSync('<plist/>');
    }
    Link(p.join(dir, 'Versions', 'Current')).createSync('A');
    Link(p.join(dir, name)).createSync('Versions/Current/$name');
    Link(p.join(dir, 'Resources')).createSync('Versions/Current/Resources');
  }

  bool exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  test('removes the skeleton an in-app update leaves, nothing else', () async {
    framework('resqlite', withBinary: false);
    framework('sqlite3');
    framework('App');
    // A link inside the skeleton that points outside it must not be followed.
    final outside = Directory(p.join(root.path, 'outside'))..createSync();
    File(p.join(outside.path, 'keep.txt')).writeAsStringSync('keep');
    Link(
      p.join(frameworks, 'resqlite.framework', 'escape'),
    ).createSync(outside.path);

    final outcome = await removeStaleMacFrameworksInBundle(contents);

    expect(outcome, StaleNativeAssetCleanupOutcome.removed);
    expect(exists(p.join(frameworks, 'resqlite.framework')), isFalse);
    expect(
      File(p.join(frameworks, 'sqlite3.framework', 'sqlite3')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(frameworks, 'App.framework', 'App')).existsSync(),
      isTrue,
    );
    expect(File(p.join(outside.path, 'keep.txt')).readAsStringSync(), 'keep');
  });

  test(
    'also removes a complete leftover copy (an older updater kept it)',
    () async {
      framework('resqlite');
      expect(
        await removeStaleMacFrameworksInBundle(contents),
        StaleNativeAssetCleanupOutcome.removed,
      );
      expect(exists(p.join(frameworks, 'resqlite.framework')), isFalse);
    },
  );

  test('a clean bundle is left alone, and the cleanup is idempotent', () async {
    framework('sqlite3');
    framework('resqlite', withBinary: false);
    await removeStaleMacFrameworksInBundle(contents);
    expect(
      await removeStaleMacFrameworksInBundle(contents),
      StaleNativeAssetCleanupOutcome.clean,
    );
    expect(
      File(p.join(frameworks, 'sqlite3.framework', 'sqlite3')).existsSync(),
      isTrue,
    );
  });

  test(
    'a framework entry that is itself a symlink loses only the link',
    () async {
      final target = Directory(p.join(root.path, 'elsewhere'))..createSync();
      File(p.join(target.path, 'keep.txt')).writeAsStringSync('keep');
      Link(p.join(frameworks, 'resqlite.framework')).createSync(target.path);

      expect(
        await removeStaleMacFrameworksInBundle(contents),
        StaleNativeAssetCleanupOutcome.removed,
      );
      expect(exists(p.join(frameworks, 'resqlite.framework')), isFalse);
      expect(File(p.join(target.path, 'keep.txt')).existsSync(), isTrue);
    },
  );

  test('outside an .app/Contents directory nothing is touched', () async {
    final notABundle = p.join(root.path, 'plain', 'Contents');
    Directory(
      p.join(notABundle, 'Frameworks', 'resqlite.framework'),
    ).createSync(recursive: true);
    final notContents = p.join(root.path, 'Chessever.app');

    expect(
      await removeStaleMacFrameworksInBundle(notABundle),
      StaleNativeAssetCleanupOutcome.skipped,
    );
    expect(
      await removeStaleMacFrameworksInBundle(notContents),
      StaleNativeAssetCleanupOutcome.skipped,
    );
    expect(
      Directory(
        p.join(notABundle, 'Frameworks', 'resqlite.framework'),
      ).existsSync(),
      isTrue,
    );
  });

  test('only bare <name>.framework entries are ever considered', () async {
    framework('sqlite3');
    Directory(p.join(contents, 'MacOS')).createSync();
    File(p.join(contents, 'MacOS', 'chessever')).writeAsStringSync('exe');

    final outcome = await removeStaleMacFrameworksInBundle(
      contents,
      frameworks: const <String>[
        '../MacOS',
        'sqlite3',
        '',
        '../../Chessever.app',
        'sub/x.framework',
      ],
    );

    expect(outcome, StaleNativeAssetCleanupOutcome.clean);
    expect(File(p.join(contents, 'MacOS', 'chessever')).existsSync(), isTrue);
    expect(
      File(p.join(frameworks, 'sqlite3.framework', 'sqlite3')).existsSync(),
      isTrue,
    );
  });

  test(
    'a bundle the user cannot write to reports failure instead of throwing',
    () async {
      framework('resqlite', withBinary: false);
      await Process.run('chmod', <String>['a-w', frameworks]);

      final logs = <String>[];
      final outcome = await removeStaleMacFrameworksInBundle(
        contents,
        log: logs.add,
      );

      expect(outcome, StaleNativeAssetCleanupOutcome.failed);
      expect(logs.single, contains('could not remove stale native asset'));
    },
    skip: Platform.isWindows ? 'POSIX permissions only' : false,
  );

  test(
    'the stale list holds only resqlite, never a framework still shipped',
    () {
      expect(staleMacFrameworks, <String>['resqlite.framework']);
    },
  );
}
