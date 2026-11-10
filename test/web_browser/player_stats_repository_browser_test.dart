@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import '../desktop/player_stats_repository_test.dart' as suite;
import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);
  suite.main();
}
