import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('My Databases cards prioritize names and relevant metadata', () {
    final source =
        File('lib/desktop/panes/library_pane.dart').readAsStringSync();
    final itemCopy = source.substring(
      source.indexOf('class _DatabaseBoardItem'),
      source.indexOf('class _LocalLibraryEntryGroup'),
    );
    final tileLayout = source.substring(
      source.indexOf('class _DatabaseBoardTile'),
      source.indexOf('class _CloudDatabaseMiniPreview'),
    );

    expect(tileLayout, isNot(contains('_LibraryKindChip(chrome: chrome)')));
    expect(itemCopy, isNot(contains("'Folder · holds databases'")));
    expect(itemCopy, isNot(contains("'Folder · ")));
    expect(itemCopy, isNot(contains("'System database'")));
    expect(itemCopy, isNot(contains("'Local database · games only'")));
    expect(itemCopy, isNot(contains("games · local'")));
  });
}
