import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'release signing repairs versioned framework roots before signing them',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'chessever_resign_frameworks_',
      );

      try {
        final targetBuildDir = Directory('${temp.path}/Build')..createSync();
        final appDir = Directory('${targetBuildDir.path}/chessever.app');
        final frameworksDir = Directory('${appDir.path}/Contents/Frameworks')
          ..createSync(recursive: true);
        final soloudFramework = _createVersionedFramework(
          frameworksDir,
          'flutter-soloud',
        );
        final swiftPackageFramework = _createVersionedFramework(
          frameworksDir,
          'FlutterFramework_-35AC8DEE1728A85C_PackageProduct',
          createCurrentSymlink: true,
        );

        final codesignLog = File('${temp.path}/codesign.log');
        final fakeCodesign = File('${temp.path}/codesign')
          ..writeAsStringSync(r'''#!/bin/sh
set -eu
target=""
for arg do
  target="$arg"
done
printf '%s\n' "$target" >> "$CODESIGN_LOG"
case "$target" in
  */Versions/*)
    echo "expected framework root, got version directory: $target" >&2
    exit 65
    ;;
  *.framework)
    name="$(basename "$target" .framework)"
    [ -e "$target/Versions/Current" ] || {
      echo "missing Versions/Current: $target" >&2
      exit 66
    }
    [ -e "$target/Resources/Info.plist" ] || {
      echo "missing Resources symlink: $target" >&2
      exit 67
    }
    [ -e "$target/$name" ] || {
      echo "missing executable symlink: $target/$name" >&2
      exit 68
    }
    ;;
esac
exit 0
''');
        await Process.run('chmod', ['+x', fakeCodesign.path]);

        final result = await Process.run(
          '/bin/sh',
          ['macos/Runner/Scripts/resign_release_frameworks.sh'],
          environment: <String, String>{
            ...Platform.environment,
            'CONFIGURATION': 'Release',
            'CODE_SIGNING_ALLOWED': 'YES',
            'TARGET_BUILD_DIR': targetBuildDir.path,
            'WRAPPER_NAME': 'chessever.app',
            'EXPANDED_CODE_SIGN_IDENTITY': 'Test Identity',
            'CODESIGN_BIN': fakeCodesign.path,
            'CODESIGN_LOG': codesignLog.path,
          },
        );

        expect(
          result.exitCode,
          0,
          reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        final signedPaths = codesignLog.readAsLinesSync();
        expect(signedPaths, contains(soloudFramework.path));
        expect(signedPaths, contains(swiftPackageFramework.path));
        expect(_hasFrameworkRootLinks(soloudFramework), isTrue);
        expect(_hasFrameworkRootLinks(swiftPackageFramework), isTrue);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: Platform.isMacOS ? false : 'macOS release signing script uses PlistBuddy.',
  );
}

Directory _createVersionedFramework(
  Directory frameworksDir,
  String name, {
  bool createCurrentSymlink = false,
}) {
  final framework = Directory('${frameworksDir.path}/$name.framework');
  final versionDir = Directory('${framework.path}/Versions/A');
  final resourcesDir = Directory('${versionDir.path}/Resources')
    ..createSync(recursive: true);

  File('${versionDir.path}/$name').writeAsStringSync('bin');
  File('${resourcesDir.path}/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$name</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
</dict>
</plist>
''');

  if (createCurrentSymlink) {
    Link('${framework.path}/Versions/Current').createSync('A');
  }

  return framework;
}

bool _hasFrameworkRootLinks(Directory framework) {
  final name = framework.path.split(Platform.pathSeparator).last.replaceAll(
        '.framework',
        '',
      );

  return Link('${framework.path}/Versions/Current').existsSync() &&
      File('${framework.path}/Resources/Info.plist').existsSync() &&
      File('${framework.path}/$name').existsSync();
}
