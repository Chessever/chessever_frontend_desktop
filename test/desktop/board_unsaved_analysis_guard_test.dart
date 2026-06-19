import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';

void main() {
  group('board unsaved analysis guard', () {
    test('requires confirmation only when local analysis changes notation', () {
      expect(
        shouldConfirmBoardAnalysisDiscard(
          dirtySinceLoad: false,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4',
        ),
        isFalse,
      );

      expect(
        shouldConfirmBoardAnalysisDiscard(
          dirtySinceLoad: true,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4 e5',
        ),
        isFalse,
      );

      expect(
        shouldConfirmBoardAnalysisDiscard(
          dirtySinceLoad: true,
          currentPgn: '1. e4 e5 2. Nf3',
          lastAppliedPgn: '1. e4 e5',
        ),
        isTrue,
      );
    });
  });
}
