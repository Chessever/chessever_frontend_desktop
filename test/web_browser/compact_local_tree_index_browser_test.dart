@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import '../desktop/compact_local_tree_index_test.dart' as scanner;
import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);
  scanner.main();
}
