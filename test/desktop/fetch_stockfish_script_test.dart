import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetch_stockfish.sh pins Stockfish 19 and packages each Mac flavor', () {
    final script = File('scripts/fetch_stockfish.sh').readAsStringSync();
    expect(script, contains('MACOS_ENGINE_ARCH'));
    expect(script, contains('VERSION="\${STOCKFISH_VERSION:-19}"'));
    expect(script, contains('stockfish-macos-universal.tar.gz'));
    expect(script, contains('stockfish-windows-x86-64-universal.zip'));
    // Archives are verified against the pinned sf_19 digests.
    expect(
      script,
      contains(
        'a1f0e3bcc5a6927a11fe6fc8e54a779754645f3c2bae2cf13420fd1957adaa77',
      ),
    );
    expect(
      script,
      contains(
        '3c8bf1f9ea66a09350a40df4f632288285ac206d99f33ab5842c408fc30b48a7',
      ),
    );
    // Apple Silicon ships the thinned arm64 slice only.
    expect(script, contains('lipo -thin arm64'));
    expect(script, contains('must not embed x86_64'));
    // Intel keeps the universal file: its x86_64 slice reads the network
    // from the arm64 slice.
    expect(script, contains('the Intel package needs the universal Stockfish'));
    expect(script, isNot(contains('lipo -create')));
  });

  test('publish script wires dual archive + dmg aliases', () {
    final script =
        File('scripts/codemagic_publish_macos.sh').readAsStringSync();
    expect(script, contains('UPDATE_PLATFORM="macos"'));
    expect(script, contains('UPDATE_PLATFORM="macos-x64"'));
    expect(script, contains('Chessever.dmg'));
    expect(script, contains('Chessever-intel.dmg'));
    expect(
      script,
      contains(r'dart run desktop_updater:archive "$UPDATE_PLATFORM"'),
    );
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

    final armBlock =
        codemagic
            .split('macos-desktop-release-arm64:')
            .last
            .split('macos-desktop-release-x64:')
            .first;
    final x64Block =
        codemagic
            .split('macos-desktop-release-x64:')
            .last
            .split('windows-desktop-release:')
            .first;
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
