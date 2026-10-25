// Entry point for the browser build served at app.chessever.com.
//
// Build with `scripts/build_web.sh` (flutter build web --wasm -t this file).
// Flutter compiles a Wasm module plus a JavaScript fallback for browsers
// without WasmGC. dartchess needs 64-bit integers, which dart2js cannot
// represent, so only the Wasm build boots the app: `dart.library.html` exists
// for dart2js and not for dart2wasm, which routes the fallback to a notice.
import 'package:chessever/web/web_boot.dart'
    if (dart.library.html) 'package:chessever/web/web_unsupported_browser.dart';

Future<void> main() => runChessEverWeb();
