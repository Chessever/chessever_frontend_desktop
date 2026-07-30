import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetch_stockfish.sh documents dual single-arch packages', () {
    final script = File('scripts/fetch_stockfish.sh').readAsStringSync();
    expect(script, contains('MACOS_ENGINE_ARCH'));
    expect(script, contains('stockfish-macos-m1-apple-silicon'));
    expect(script, contains('stockfish-macos-x86-64-avx2'));
    expect(script, contains('must not embed x86_64'));
    expect(script, contains('must not embed arm64'));
    // Explicitly rejects fat Stockfish.
    expect(script, isNot(contains('lipo -create')));
  });

  test('publish script wires dual archive + dmg aliases', () {
    final script = File('scripts/codemagic_publish_macos.sh').readAsStringSync();
    expect(script, contains('UPDATE_PLATFORM="macos"'));
    expect(script, contains('UPDATE_PLATFORM="macos-x64"'));
    expect(script, contains('Chessever.dmg'));
    expect(script, contains('Chessever-intel.dmg'));
    expect(script, contains(r'dart run desktop_updater:archive "$UPDATE_PLATFORM"'));
    expect(
      script,
      contains(r'ingest $UPDATE_PLATFORM $ARCHIVE_NAME $RELEASE_VERSION'),
    );
    expect(script, contains('must be a single-arch binary'));
    expect(script, contains(r'--arch='));
  });

  test('codemagic builds arm64 and x64 packages on separate workflows', () {
    final codemagic = File('codemagic.yaml').readAsStringSync();
    expect(codemagic, contains('macos-desktop-release-arm64:'));
    expect(codemagic, contains('macos-desktop-release-x64:'));
    // Split so Apple Silicon can track Flutter beta while Intel stays on stable.
    expect(codemagic, isNot(contains('for ARCH in arm64 x64')));
    expect(codemagic, contains('MACOS_ENGINE_ARCH'));
    expect(codemagic, contains('--dart-define=MACOS_RELEASE_ARCH'));
    expect(codemagic, contains('codemagic_publish_macos.sh --arch'));
    expect(codemagic, isNot(contains('lipo -create')));

    final armBlock = codemagic.split('macos-desktop-release-arm64:').last.split(
      'macos-desktop-release-x64:',
    ).first;
    final x64Block = codemagic.split('macos-desktop-release-x64:').last.split(
      'windows-desktop-release:',
    ).first;
    expect(armBlock, contains('flutter: beta'));
    expect(armBlock, contains('ARCH=arm64'));
    // Continuous Silicon slug is bare macos, not macos-arm64.
    expect(armBlock, contains('desktop_updater:release macos --release'));
    expect(armBlock, isNot(contains('desktop_updater:release "macos-arm64"')));
    expect(x64Block, contains('flutter: stable'));
    expect(x64Block, contains('ARCH=x64'));
    expect(x64Block, contains('desktop_updater:release macos-x64 --release'));
  });
}
