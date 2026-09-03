import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/panes/library_pane.dart';

void main() {
  test('Library Home uses the dense mixed catalog contract', () {
    final source =
        File('lib/desktop/panes/library_pane.dart').readAsStringSync();
    final itemCopy = source.substring(
      source.indexOf('class _DatabaseBoardItem'),
      source.indexOf('class _LocalLibraryEntryGroup'),
    );
    final boardLayout = source.substring(
      source.indexOf('class _MyDatabasesBoard'),
      source.indexOf('class _LibraryBlockingProgressOverlay'),
    );
    final headerLayout = source.substring(
      source.indexOf('class _MyDatabasesHeader'),
      source.indexOf('class _MyDatabasesBoard'),
    );
    final rowLayout = source.substring(
      source.indexOf('class _DatabaseBoardRow'),
      source.indexOf('class _CloudDatabaseMiniPreview'),
    );
    final previewLayout = source.substring(
      source.indexOf('class _CloudDatabaseMiniPreview'),
      source.indexOf('class _FolderContentView'),
    );
    final clipboardOpenFlow = source.substring(
      source.indexOf('Future<void> openClipboardPgnDatabase()'),
      source.indexOf('void openLocalFullView(String path)'),
    );

    final toolbarSource =
        File(
          'lib/desktop/widgets/library/library_actions_toolbar.dart',
        ).readAsStringSync();

    expect(headerLayout, contains("'Library'"));
    expect(source, contains("'Cloud Library'"));
    expect(headerLayout, contains("hintText: 'Search library'"));
    expect(source, contains("'All'"));
    expect(source, contains("'Cloud'"));
    expect(source, contains("'Local'"));
    expect(headerLayout, isNot(contains('Icons.view_list_rounded')));
    expect(headerLayout, isNot(contains('Icons.grid_view_rounded')));
    expect(headerLayout, isNot(contains('bottom: LayoutBuilder')));
    expect(headerLayout, isNot(contains('Local & cloud')));
    expect(headerLayout, isNot(contains('_LibraryFolderBreadcrumb')));
    expect(headerLayout, contains('Icons.collections_bookmark_outlined'));
    expect(headerLayout, isNot(contains('Icons.view_sidebar_outlined')));
    expect(boardLayout, contains("label: 'Preview database'"));
    expect(boardLayout, contains("label: 'Open full database'"));
    expect(boardLayout, contains("label: 'Remove from Library Home'"));
    expect(boardLayout, contains("label: 'Delete from computer'"));
    expect(boardLayout, contains("'Pin database'"));
    expect(boardLayout, contains("'Unpin database'"));
    expect(boardLayout, contains('compareLibraryDatabaseCatalogPinState'));
    expect(source, contains("'NAME'"));
    expect(source, contains("'GAMES'"));
    expect(source, contains("'SOURCE'"));
    expect(source, contains("'LAST OPENED'"));
    expect(source, contains('_dragWidth += details.delta.dx'));
    expect(source, isNot(contains("label: 'Sort: Modified'")));
    expect(source, isNot(contains("'Format'")));
    expect(source, isNot(contains("'Modified'")));
    expect(source, isNot(contains('New sub-folder')));
    expect(toolbarSource, contains("'Import'"));
    expect(toolbarSource, contains("'Folder'"));
    expect(toolbarSource, contains("'Database'"));
    expect(toolbarSource, contains("'Paste'"));
    expect(toolbarSource, contains('Icons.content_paste_rounded'));
    expect(toolbarSource, isNot(contains('Icons.content_paste_go_rounded')));
    expect(clipboardOpenFlow, contains('openDatabaseWorkspaceTab('));
    expect(clipboardOpenFlow, contains('DatabaseWorkspaceArgs.local('));
    expect(clipboardOpenFlow, contains("title: 'Clipboard PGN'"));
    expect(clipboardOpenFlow, isNot(contains('libraryImportBufferProvider')));
    expect(rowLayout, contains('onSecondaryTapUp:'));
    expect(rowLayout, isNot(contains('onSecondaryTapDown:')));
    expect(rowLayout, isNot(contains('MotionCard(')));
    expect(rowLayout, contains('Draggable<String>'));
    expect(rowLayout, contains('DragTarget<String>'));
    expect(boardLayout, contains('reorderingEnabled'));
    expect(boardLayout, contains('selectedLocalGroupId'));
    expect(previewLayout, isNot(contains('Search this database')));
    expect(previewLayout, isNot(contains('DesktopGameFilterButton')));
    expect(previewLayout, isNot(contains('LocalTreeActionButton')));
    expect(previewLayout, isNot(contains('· mini preview')));
    expect(itemCopy, isNot(contains("'Folder · holds databases'")));
    expect(itemCopy, isNot(contains("'Folder · ")));
    expect(itemCopy, isNot(contains("'System database'")));
    expect(itemCopy, isNot(contains("'Local database · games only'")));
    expect(itemCopy, isNot(contains("games · local'")));
  });

  testWidgets('dense database rows dispatch right-click menus', (tester) async {
    var selections = 0;
    var opens = 0;
    Offset? menuPosition;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            child: buildLibraryDatabaseCatalogRowForTest(
              title: 'Preparation',
              onSelect: () => selections++,
              onOpen: () => opens++,
              onContextMenu: (position) => menuPosition = position,
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('Preparation')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();

    expect(selections, 1);
    expect(opens, 0);
    expect(menuPosition, isNotNull);
  });

  testWidgets('catalog rows clamp saved widths to their real constraints', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 620,
          child: buildLibraryDatabaseCatalogRowForTest(
            title: 'Preparation',
            columns: const LibraryDatabaseCatalogColumns(
              showSource: true,
              showLastOpened: true,
              nameWidth: 520,
              gamesWidth: 190,
              sourceWidth: 160,
              lastOpenedWidth: 200,
            ),
            onSelect: () {},
            onOpen: () {},
            onContextMenu: (_) {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
