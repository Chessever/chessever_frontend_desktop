import 'dart:convert';
import 'dart:typed_data';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/board_share_service.dart';
import 'package:chessever/desktop/services/cloudflare_gif_service.dart';
import 'package:chessever/desktop/widgets/board_share_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  group('boardShareGifProgressText', () {
    CloudflareGifJob job({
      CloudflareGifJobStatus stage = CloudflareGifJobStatus.queued,
      int completedFrames = 0,
      int totalFrames = 0,
    }) {
      return CloudflareGifJob(
        id: 'job-1',
        status: stage,
        stage: stage,
        completedFrames: completedFrames,
        totalFrames: totalFrames,
        expiresAt: DateTime.utc(2030),
      );
    }

    test('queued label is product-neutral and omits vendor names', () {
      final label = boardShareGifProgressText(job());
      expect(label, 'Queued…');
      expect(label.toLowerCase(), isNot(contains('cloudflare')));
      expect(label.toLowerCase(), isNot(contains('cloud')));
    });

    test('maps every stage without vendor branding', () {
      final labels = CloudflareGifJobStatus.values
          .map((stage) => boardShareGifProgressText(job(stage: stage)))
          .toList();
      for (final label in labels) {
        expect(label.toLowerCase(), isNot(contains('cloudflare')));
        expect(label, isNot(contains('Cloudflare')));
      }
      expect(
        boardShareGifProgressText(
          job(
            stage: CloudflareGifJobStatus.rendering,
            completedFrames: 3,
            totalFrames: 10,
          ),
        ),
        'Rendering frames 3/10…',
      );
      expect(
        boardShareGifProgressText(job(stage: CloudflareGifJobStatus.queued)),
        isNot(contains('Cloudflare')),
      );
    });
  });

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

  group('boardShareActionDescriptors', () {
    test('uses copy-image/download actions for desktop sharing', () {
      final actions = boardShareActionDescriptors(
        copyImage: () {},
        generateGif: () {},
        downloadImage: () {},
        copyPgn: () {},
      );

      expect(actions.map((action) => action.label), [
        'Copy Image',
        'Generate GIF',
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

    test('only offers download after the GIF has been generated', () {
      final actions = boardShareGeneratedGifActionDescriptors(
        downloadGif: () {},
      );

      expect(actions.map((action) => action.label), ['Download GIF']);
    });
  });

  group('BoardShareRaster', () {
    test('reuses the supplied live capture for copy and download', () async {
      final liveCapture = Uint8List.fromList([1, 2, 3, 4]);
      var fallbackCaptureCalls = 0;
      final raster = BoardShareRaster(
        liveBoardPngBytes: liveCapture,
        fallbackCapture: () async {
          fallbackCaptureCalls++;
          return Uint8List.fromList([9, 9, 9]);
        },
      );

      final copiedBytes = await raster.bytes();
      final downloadedBytes = await raster.bytes();

      expect(identical(copiedBytes, liveCapture), isTrue);
      expect(identical(downloadedBytes, liveCapture), isTrue);
      expect(fallbackCaptureCalls, 0);
    });

    test('captures a non-live fallback only once per dialog session', () async {
      final fallbackCapture = Uint8List.fromList([5, 6, 7]);
      var fallbackCaptureCalls = 0;
      final raster = BoardShareRaster(
        liveBoardPngBytes: null,
        fallbackCapture: () async {
          fallbackCaptureCalls++;
          return fallbackCapture;
        },
      );

      final firstExport = await raster.bytes();
      final secondExport = await raster.bytes();

      expect(identical(firstExport, fallbackCapture), isTrue);
      expect(identical(secondExport, fallbackCapture), isTrue);
      expect(fallbackCaptureCalls, 1);
    });
  });

  testWidgets('previews the supplied live Board-pane raster', (tester) async {
    final liveCapture = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL6fQAAAABJRU5ErkJggg==',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: BoardShareDialog(
            chessGame: ChessGame.fromPgn('share-preview', '1. e4 *'),
            headers: const {},
            position: Chess.initial,
            lastMove: null,
            pointer: const [],
            flipped: false,
            liveBoardPngBytes: liveCapture,
          ),
        ),
      ),
    );

    final preview = tester.widget<Image>(
      find.byKey(const ValueKey<String>('board-share-live-preview')),
    );
    expect(preview.image, isA<MemoryImage>());
    expect((preview.image as MemoryImage).bytes, same(liveCapture));
    expect(find.byType(cg.StaticChessboard), findsNothing);
  });

  test('share view defaults the eval gauge to off', () {
    final dialog = BoardShareDialog(
      chessGame: ChessGame.fromPgn('share-defaults', '1. e4 *'),
      headers: const {},
      position: Chess.initial,
      lastMove: null,
      pointer: const [],
      flipped: false,
    );

    expect(dialog.showEvalBar, isFalse);
  });

  test('share view accepts the board-resolved player identity', () {
    final dialog = BoardShareDialog(
      chessGame: ChessGame.fromPgn('share-player-identity', '1. e4 *'),
      headers: const {},
      position: Chess.initial,
      lastMove: null,
      pointer: const [],
      flipped: false,
      whiteFideId: 4168119,
      blackFideId: 724342,
      whitePhotoUrl: 'https://example.com/white.webp',
      blackPhotoUrl: 'https://example.com/black.webp',
    );

    expect(dialog.whiteFideId, 4168119);
    expect(dialog.blackFideId, 724342);
    expect(dialog.whitePhotoUrl, endsWith('/white.webp'));
    expect(dialog.blackPhotoUrl, endsWith('/black.webp'));
  });

  test('cloud GIF photo MIME detection uses image signatures', () {
    expect(
      cloudGifPhotoMimeType(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]),
      ),
      'image/png',
    );
    expect(
      cloudGifPhotoMimeType(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0])),
      'image/jpeg',
    );
    expect(
      cloudGifPhotoMimeType(
        Uint8List.fromList([
          0x52,
          0x49,
          0x46,
          0x46,
          0,
          0,
          0,
          0,
          0x57,
          0x45,
          0x42,
          0x50,
        ]),
      ),
      'image/webp',
    );
    expect(cloudGifPhotoMimeType(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
