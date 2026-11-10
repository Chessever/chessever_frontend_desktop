@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import '../desktop/player_build_tree_seed_test.dart' as scanner;
import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);
  scanner.main();
}
