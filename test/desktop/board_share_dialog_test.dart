import 'dart:typed_data';

import 'package:chessground/chessground.dart' as cg;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/board_share_service.dart';
import 'package:chessever/desktop/widgets/board_share_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';

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

  group('BoardShareCard', () {
    testWidgets('renders player bars and real clocks when provided', (
      tester,
    ) async {
      const settings = BoardSettingsNew();
      await tester.pumpWidget(
        MaterialApp(
          home: BoardShareCard(
            fen: 'rn1qkbnr/pppbpppp/8/3p4/8/5NP1/PPPPPPBP/RNBQK2R b KQkq - 1 3',
            boardSettings: cg.ChessboardSettings(
              enableCoordinates: true,
              animationDuration: Duration.zero,
              colorScheme: settings.colorScheme,
              pieceAssets: settings.pieceAssets,
              borderRadius: BorderRadius.zero,
              boxShadow: const [],
            ),
            whiteName: 'Hans Niemann',
            blackName: 'Magnus Carlsen',
            whiteClock: '1:23:45',
            blackClock: '0:12:34',
            event: '12th Cesme International Open Chess Tournament',
          ),
        ),
      );

      expect(find.text('Hans Niemann'), findsOneWidget);
      expect(find.text('Magnus Carlsen'), findsOneWidget);
      expect(find.text('1:23:45'), findsOneWidget);
      expect(find.text('12:34'), findsOneWidget);
    });

    testWidgets('omits the eval bar completely when hidden', (tester) async {
      const settings = BoardSettingsNew();
      await tester.pumpWidget(
        MaterialApp(
          home: BoardShareCard(
            fen: 'rn1qkbnr/pppbpppp/8/3p4/8/5NP1/PPPPPPBP/RNBQK2R b KQkq - 1 3',
            boardSettings: cg.ChessboardSettings(
              enableCoordinates: true,
              animationDuration: Duration.zero,
              colorScheme: settings.colorScheme,
              pieceAssets: settings.pieceAssets,
              borderRadius: BorderRadius.zero,
              boxShadow: const [],
            ),
            whiteName: 'Hans Niemann',
            blackName: 'Magnus Carlsen',
            showEvalBar: false,
          ),
        ),
      );

      expect(find.byType(DesktopEvalBar), findsNothing);
      expect(boardShareCardWidth(320, showEvalBar: false), 320);
    });
  });

  group('boardShareVisibleUrl', () {
    test('keeps trimmed game links visible under the title', () {
      expect(
        boardShareVisibleUrl(' https://chessever.com/games/game-123 '),
        'https://chessever.com/games/game-123',
      );
      expect(boardShareVisibleUrl('   '), isNull);
      expect(boardShareVisibleUrl(null), isNull);
    });
  });

  group('exact board image', () {
    test('uses the live rendered crop without rebuilding the board', () async {
      final exact = Uint8List.fromList([1, 2, 3]);
      var fallbackCalls = 0;

      final result = await resolveBoardSharePngBytes(
        exactImageBytes: exact,
        captureFallback: () async {
          fallbackCalls++;
          return Uint8List.fromList([9]);
        },
      );

      expect(result, same(exact));
      expect(fallbackCalls, 0);
    });

    test('falls back to the reconstructed card outside a live board', () async {
      final fallback = Uint8List.fromList([9, 8]);

      final result = await resolveBoardSharePngBytes(
        captureFallback: () async => fallback,
      );

      expect(result, same(fallback));
    });
  });

  group('boardShareActionDescriptors', () {
    test('uses copy-image/download actions for desktop sharing', () {
      final actions = boardShareActionDescriptors(
        copyImage: () {},
        downloadGif: () {},
        downloadImage: () {},
        copyPgn: () {},
      );

      expect(actions.map((action) => action.label), [
        'Copy Image',
        'Download GIF',
        'Download PNG',
        'Copy PGN',
      ]);
      expect(
        actions.map((action) => action.label),
        isNot(contains('Copy Link')),
      );
      expect(
        actions.map((action) => action.label),
        isNot(contains('Download Image')),
      );
      expect(
        actions.map((action) => action.label),
        isNot(contains('Share GIF')),
      );
    });
  });
}
