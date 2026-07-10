import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/widgets/library/local_chess_files_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('writable cloud database row menu offers Paste games', () {
    expect(
      debugDatabaseSavedGameContextMenuLabels(canPaste: true),
      contains('Paste games'),
    );
  });

  test('read-only cloud database row menu omits Paste games', () {
    expect(
      debugDatabaseSavedGameContextMenuLabels(canPaste: false),
      isNot(contains('Paste games')),
    );
  });

  test('local database row menu offers Paste games', () {
    expect(
      debugLocalGameRowContextMenuLabels(canPaste: true),
      contains('Paste games'),
    );
  });
}
