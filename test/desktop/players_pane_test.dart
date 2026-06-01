import 'package:chessever/desktop/panes/players_pane.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop player list labels', () {
    test('keeps title pill value out of displayed player name', () {
      expect(
        desktopPlayerDisplayName({'title': 'GM', 'name': 'GM Carlsen, Magnus'}),
        'Carlsen, Magnus',
      );
      expect(
        desktopPlayerDisplayName({'title': 'IM', 'name': 'im Smith, John'}),
        'Smith, John',
      );
    });

    test('keeps names without a duplicated title unchanged', () {
      expect(
        desktopPlayerDisplayName({'title': 'GM', 'name': 'Carlsen, Magnus'}),
        'Carlsen, Magnus',
      );
      expect(
        desktopPlayerDisplayName({'name': 'Polgar, Judit'}),
        'Polgar, Judit',
      );
    });

    test('shows one-based row numbers for player rank labels', () {
      expect(desktopPlayerRankLabel(1), '1');
      expect(desktopPlayerRankLabel(12), '12');
    });
  });
}
