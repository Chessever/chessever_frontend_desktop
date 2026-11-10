@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import '../desktop/local_chess_library_test.dart' as scanner;
import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);
  scanner.main();
}
