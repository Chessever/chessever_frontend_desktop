import 'dart:convert';
import 'dart:io';
import 'package:chessever/desktop/utils/library_folder_tree.dart';

class Node {
  Node(this.key, [this.parent]);
  final String key;
  final String? parent;
  final children = <Node>[];
}

void check(bool value, String label) {
  if (!value) throw StateError(label);
}

void main() {
  final root = Node('cloud:collections');
  final nested = Node('cloud:nested', root.key);
  final ulvi = Node('cloud:ulvi', nested.key);
  final unrelated = Node('local:games');
  root.children.add(nested);
  nested.children.add(ulvi);
  Map<String, bool> state = {};
  List<LibraryFolderTreeRow<Node>> rows({
    bool Function(Node)? matches,
    List<Node>? roots,
  }) => projectLibraryFolderTree(
    roots: roots ?? [root, unrelated],
    keyOf: (n) => n.key,
    childrenOf: (n) => n.children,
    isExpanded: (n) => state[n.key] ?? true,
    matches: matches,
  );
  check(
    rows().map((r) => r.item.key).join('|') ==
        'cloud:collections|cloud:nested|cloud:ulvi|local:games',
    'expanded forest and stable ordering',
  );
  state = toggleLibraryFolderExpansion(state, root.key, defaultExpanded: true);
  check(
    rows().length == 2 && rows().last.item == unrelated,
    'collapse hides all descendants only',
  );
  state = toggleLibraryFolderExpansion(state, root.key, defaultExpanded: true);
  check(rows().length == 4, 'expand restores children');
  state = toggleLibraryFolderExpansion(
    state,
    nested.key,
    defaultExpanded: true,
  );
  check(rows().length == 3, 'nested branch collapse');
  state = readLibraryFolderExpansion(jsonDecode(jsonEncode(state)));
  check(
    state[nested.key] == false && rows().length == 3,
    'false survives serialization and reopen',
  );
  final found = rows(matches: (n) => n == ulvi);
  check(
    found.length == 3 && found.last.item == ulvi && found[1].expanded,
    'search reveals matching descendants with ancestor context',
  );
  check(
    state[nested.key] == false,
    'search does not overwrite stored expansion',
  );
  nested.children.add(root);
  check(
    rows().map((r) => r.item.key).toSet().length == rows().length,
    'cycles cannot duplicate or hang',
  );
  nested.children.remove(root);
  state = {};
  check(
    rows(roots: [ulvi, root]).where((r) => r.item == ulvi).length == 1,
    'pinned descendant has one authoritative placement',
  );
  final group = Node('group:player');
  final db = Node('local:prep', group.key);
  group.children.add(db);
  check(
    rows(roots: [group]).last.item == db,
    'local group databases use same projection',
  );
  check(
    rows().first.depth == 0 && rows()[1].depth == 1 && rows()[2].depth == 2,
    'nested indentation depth',
  );
  final clean = readLibraryFolderExpansion({
    'a': false,
    'b': true,
    'c': 2,
    '': false,
  });
  check(
    clean.length == 2 && clean['a'] == false && clean['b'] == true,
    'malformed persisted values ignored',
  );
  final orphan = Node('orphan', 'missing');
  check(
    libraryFolderTreeRoots(
          items: [root, nested, ulvi, orphan],
          keyOf: (n) => n.key,
          parentKeyOf: (n) => n.parent,
        ).length ==
        2,
    'orphan roots remain reachable without promoting valid descendants',
  );
  stdout.writeln(
    'PASS: 13 folder hierarchy, collapse, search, pin and persistence checks',
  );
}
