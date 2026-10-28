import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

/// Board sounds for the browser build, played through `<audio>` elements.
///
/// flutter_soloud's web build busy-waits on the main thread unless the page is
/// cross-origin isolated; every move sound froze the board for up to a second.
/// An audio element plays off the main thread and costs nothing between moves.
class WebSfxPlayer {
  final Map<String, web.HTMLAudioElement> _elements = {};

  /// Starts downloading [assetPaths] so the first move plays without a delay.
  void preload(Iterable<String> assetPaths) {
    assetPaths.forEach(_element);
  }

  void play(String assetPath, double volume) {
    final element =
        _element(assetPath)
          ..volume = volume.clamp(0.0, 1.0).toDouble()
          ..currentTime = 0;
    // Browsers refuse audio until the visitor has interacted with the page;
    // a refused sound is skipped rather than reported.
    unawaited(element.play().toDart.then((_) {}, onError: (Object _) {}));
  }

  web.HTMLAudioElement _element(String assetPath) =>
      _elements.putIfAbsent(
        assetPath,
        () =>
            web.HTMLAudioElement()
              ..preload = 'auto'
              ..src = ui_web.assetManager.getAssetUrl(assetPath),
      );
}
