import 'package:chessever/repository/library/library_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('libraryFolderTreeIds', () {
    test('returns root and every nested descendant depth-first', () {
      final rows = <Map<String, Object?>>[
        {'id': 'root', 'parent_id': null},
        {'id': 'database-a', 'parent_id': 'root'},
        {'id': 'folder-b', 'parent_id': 'database-a'},
        {'id': 'database-c', 'parent_id': 'folder-b'},
        {'id': 'folder-d', 'parent_id': 'root'},
        {'id': 'unrelated', 'parent_id': null},
      ];

      expect(libraryFolderTreeIds('root', rows), <String>[
        'root',
        'database-a',
        'folder-b',
        'database-c',
        'folder-d',
      ]);
    });

    test('is cycle-safe and ignores missing roots', () {
      final rows = <Map<String, Object?>>[
        {'id': 'a', 'parent_id': 'c'},
        {'id': 'b', 'parent_id': 'a'},
        {'id': 'c', 'parent_id': 'b'},
        {'id': 'unrelated', 'parent_id': null},
      ];

      expect(libraryFolderTreeIds('a', rows), <String>['a', 'b', 'c']);
      expect(libraryFolderTreeIds('missing', rows), isEmpty);
      expect(libraryFolderTreeIds('', rows), isEmpty);
    });
  });
}
