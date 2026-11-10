// Shared setup for tests that run the local-database code in a real browser
// (`flutter test --platform chrome --wasm test/web_browser`), over the same
// virtual filesystem and SQLite Wasm driver as app.chessever.com.
//
// Serve the SQLite module first: `python3 test/web_browser/serve_wasm.py`.
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:chessever/web/shims/local_sqlite_web.dart';
import 'package:chessever/web/web_file_system.dart';
import 'package:chessever/web/web_path_provider.dart';

bool _mounted = false;

Future<void> mountBrowserLocalDatabase() async {
  if (_mounted) return;
  _mounted = true;
  TestWidgetsFlutterBinding.ensureInitialized();
  debugLocalSqliteWasmUrl =
      'http://127.0.0.1:8377/sqlite/sqlite3-3.8.0.wasm';
  await WebFileSystem.mount();
  PathProviderPlatform.instance = WebPathProvider();
}
