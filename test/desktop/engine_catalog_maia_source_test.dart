import 'dart:io';

import 'package:chessever/desktop/services/play/engine_catalog.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // maiachess.com answers app and CI downloads with a bot checkpoint (HTTP
  // 429), so every client fetches Maia from our content-addressed copy.
  test('Maia downloads come from our release Worker, not maiachess.com', () {
    final artifact = kEngineCatalog[BotEngineKind.maia]!.artifacts.single;
    final uri = Uri.parse(artifact.url);
    expect(uri.scheme, 'https');
    expect(uri.host, 'chessever.com');
    expect(
      uri.path,
      '/updates/engines/maia3/${artifact.sha256}/maia3_simplified.onnx',
    );
  });

  test('the Mac App Store bundle pins the same Maia model', () {
    final artifact = kEngineCatalog[BotEngineKind.maia]!.artifacts.single;
    final script =
        File('scripts/prepare_mac_app_store_engines.py').readAsStringSync();
    expect(script, contains(artifact.url));
    expect(script, contains('"${artifact.sha256}"'));
  });
}
