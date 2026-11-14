import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('full game view opts only draw tints into under-piece painting', () {
    final pane = File('lib/desktop/panes/board_pane.dart').readAsStringSync();
    final boardCall = pane.substring(pane.indexOf('child: DesktopChessBoard('));
    expect(
      boardCall,
      contains('squareHighlightsUnderPieces: gameEnding?.isDraw ?? false'),
      reason:
          'The full game renderer must put draw tints below both kings; '
          'keep decisive endings and other highlight callers unchanged.',
    );
  });
}
