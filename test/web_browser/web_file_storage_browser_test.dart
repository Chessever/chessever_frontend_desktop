@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/web/web_file_system.dart';

import 'harness.dart';

void main() {
  setUpAll(mountBrowserLocalDatabase);

  // Two tabs writing their own copies of the files into one IndexedDB store
  // leave database files made of chunks from both. Only the first may save.
  test('only one holder of the file store saves to it', () async {
    expect(WebFileSystem.instance.storage, WebFileStorage.saved);
    expect(await WebFileSystem.debugBecomeWriter(), isFalse);
  });
}
