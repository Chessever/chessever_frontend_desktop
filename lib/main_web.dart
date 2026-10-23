// Browser entrypoint for app.chessever.com. Build it with
// `scripts/build_web.sh`, which runs `flutter build web --wasm -t
// lib/main_web.dart`; lib/main.dart stays the native desktop entrypoint.
//
// The app only runs under dart2wasm: dartchess keeps bitboards in 64-bit
// integers, which dart2js cannot represent. `flutter build web --wasm` still
// emits a dart2js fallback, so that compile gets a small "unsupported browser"
// app instead (dart:html exists for dart2js and not for dart2wasm). The
// bootstrap script never loads it on a browser it can tell is unsupported.
import 'package:chessever/desktop/web/web_main.dart'
    if (dart.library.html) 'package:chessever/desktop/web/web_unsupported_main.dart';

Future<void> main() => webMain();
