import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/board_share_dialog.dart';

void main() {
  group('boardShareDisplayEvent', () {
    test('returns broadcast name when available', () {
      expect(
        boardShareDisplayEvent({
          'Event': 'Round 9: Board 1',
          'BroadcastName': 'Chicago Open 2026',
        }),
        'Chicago Open 2026',
      );
    });

    test('falls back to event when broadcast name is absent', () {
      expect(
        boardShareDisplayEvent({'Event': 'Round 9: Board 1'}),
        'Round 9: Board 1',
      );
    });

    test('treats empty and unknown values as absent', () {
      expect(
        boardShareDisplayEvent({'BroadcastName': ' ', 'Event': '?'}),
        isNull,
      );
    });
  });

  group('boardShareActionDescriptors', () {
    test('uses copy/download actions for desktop sharing', () {
      final actions = boardShareActionDescriptors(
        copyLink: () {},
        downloadGif: () {},
        downloadImage: () {},
        copyPgn: () {},
      );

      expect(actions.map((action) => action.label), [
        'Copy Link',
        'Download GIF',
        'Download Image',
        'Copy PGN',
      ]);
      expect(
        actions.map((action) => action.label),
        isNot(contains('Share Image')),
      );
      expect(
        actions.map((action) => action.label),
        isNot(contains('Share GIF')),
      );
    });
  });
}
