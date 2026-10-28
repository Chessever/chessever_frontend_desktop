import 'dart:convert';
import 'dart:io';
import 'package:chessever/desktop/utils/library_folder_tree.dart';
import 'package:flutter_test/flutter_test.dart';

class Item {
  const Item(this.id, this.rank);
  final String id;
  final int rank;
}

var checks = 0;
void check(bool value, String label) {
  checks++;
  if (!value) throw StateError(label);
}

void main() {
  test('Folders section collapse keeps headings and sibling sections', _checks);
}

void _checks() {
  const pinned = Item('pin', 0);
  const pinnedChild = Item('pinned-folder-child', 1);
  const folder = Item('folder', 1);
  const child = Item('child', 2);
  const database = Item('database', 2);
  final rows = [
    const LibraryFolderTreeRow(pinned, pinned, 0, true),
    const LibraryFolderTreeRow(pinnedChild, pinned, 1, false),
    const LibraryFolderTreeRow(folder, folder, 0, true),
    const LibraryFolderTreeRow(child, folder, 1, false),
    const LibraryFolderTreeRow(database, database, 0, false),
  ];
  List<LibraryCatalogSectionRow<Item>> project(
    bool expanded, {
    bool sections = true,
    List<LibraryFolderTreeRow<Item>>? input,
  }) => projectLibraryCatalogSections(
    rows: input ?? rows,
    sectionOfRoot: (item) => item.rank,
    foldersExpanded: expanded,
    showSections: sections,
  );
  String signature(List<LibraryCatalogSectionRow<Item>> result) => result
      .map(
        (r) => r.section == null ? r.treeRow!.item.id : 'header:${r.section}',
      )
      .join('|');
  check(
    signature(project(false)) ==
        'header:0|pin|pinned-folder-child|header:1|header:2|database',
    'Folders header survives; only its own roots and descendants disappear',
  );
  check(
    signature(project(true)) ==
        'header:0|pin|pinned-folder-child|header:1|folder|child|header:2|database',
    'expanding restores exact rows and order',
  );
  check(
    identical(project(true)[4].treeRow, rows[2]),
    'individual row expansion objects retained',
  );
  check(
    signature(project(false, sections: false)) ==
        'pin|pinned-folder-child|folder|child|database',
    'entered folders without section headers never lose rows',
  );
  final onlyFolders = project(false, input: [rows[2], rows[3]]);
  check(
    onlyFolders.length == 1 && onlyFolders.single.section == 1,
    'all-folder library keeps clickable header instead of empty state',
  );
  check(
    project(false, input: []).isEmpty,
    'genuine empty/filter result stays empty',
  );
  var state = <String, bool>{'home:group:folder': true};
  state = toggleLibraryFolderExpansion(
    state,
    'section:home:folders',
    defaultExpanded: true,
  );
  check(
    state['section:home:folders'] == false &&
        state['home:group:folder'] == true,
    'section preference is independent of per-folder preference',
  );
  final restored = readLibraryFolderExpansion(jsonDecode(jsonEncode(state)));
  check(
    restored['section:home:folders'] == false &&
        restored['home:group:folder'] == true,
    'explicit section collapse survives persistence',
  );
  stdout.writeln('PASS: $checks section disclosure checks');
}
