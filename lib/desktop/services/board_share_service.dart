import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chessever/screens/chessboard/widgets/gif_export_worker.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop-native sharing helpers for the board pane.
///
/// Handles image capture, GIF generation, clipboard, and disk save
/// without depending on mobile-specific game models.
class BoardShareService {
  BoardShareService._();

  /// Capture [widget] off-screen and return its PNG bytes.
  static Future<Uint8List?> captureWidget(Widget widget, {
    required double width,
    required double height,
    double pixelRatio = 2.0,
  }) async {
    final controller = ScreenshotController();
    final repainter = Material(
      type: MaterialType.transparency,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(800, 800)),
          child: SizedBox(
            width: width,
            height: height,
            child: widget,
          ),
        ),
      ),
    );

    // Render off-screen using ScreenshotController's internal pipeline
    return controller.captureFromWidget(
      repainter,
      delay: const Duration(milliseconds: 100),
      pixelRatio: pixelRatio,
      context: null,
    );
  }

  /// Share PNG bytes via the native share sheet.
  static Future<void> sharePngBytes(Uint8List bytes, {String? subject}) async {
    final tempDir = await getTemporaryDirectory();
    final file = io.File('${tempDir.path}/chessever_share.png');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: subject ?? 'ChessEver Position',
      sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
    );
  }

  /// Save PNG bytes to a user-chosen path (desktop Save dialog).
  static Future<void> savePngBytesToDisk(Uint8List bytes, {
    String defaultName = 'chessever_position.png',
  }) async {
    String? outputPath;
    if (io.Platform.isMacOS || io.Platform.isWindows || io.Platform.isLinux) {
      outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Position Image',
        fileName: defaultName,
        type: FileType.image,
        allowedExtensions: ['png'],
      );
    }
    if (outputPath == null) {
      // Fallback to Downloads / temp
      final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
      outputPath = '${dir.path}/$defaultName';
    }
    final file = io.File(outputPath);
    await file.writeAsBytes(bytes);
  }

  /// Copy [text] to the system clipboard and optionally show a toast.
  static Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Generate a GIF from a list of board positions.
  ///
  /// [frames] is a list of (fen, lastMove) tuples representing each frame.
  /// [durationsCs] is the duration of each frame in centiseconds.
  /// [boardSettings] controls the visual theme.
  ///
  /// Returns the encoded GIF bytes, or null if generation failed.
  static Future<Uint8List?> generateGif({
    required List<({String fen, Move? lastMove})> frames,
    required List<int> durationsCs,
    required cg.ChessboardSettings boardSettings,
  }) async {
    if (frames.isEmpty) return null;

    final rgbaFrames = <Uint8List>[];
    final widths = <int>[];
    final heights = <int>[];

    const boardSize = 400.0;
    const pixelRatio = 1.5;

    for (int i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final board = cg.Chessboard.fixed(
        size: boardSize,
        settings: boardSettings.copyWith(animationDuration: Duration.zero),
        orientation: Side.white,
        fen: frame.fen,
        lastMove: frame.lastMove,
      );

      final bytes = await captureWidget(board, width: boardSize, height: boardSize, pixelRatio: pixelRatio);
      if (bytes == null) continue;

      // Decode PNG to raw RGBA for the GIF encoder
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      final image = frameInfo.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width;
      final h = image.height;
      image.dispose();
      codec.dispose();

      if (byteData == null) continue;
      rgbaFrames.add(byteData.buffer.asUint8List());
      widths.add(w);
      heights.add(h);
    }

    if (rgbaFrames.isEmpty) return null;

    return encodeGifFallback(
      rgbaFrames: rgbaFrames,
      widths: widths,
      heights: heights,
      durationsCs: durationsCs,
    );
  }

  /// Share GIF bytes via the native share sheet.
  static Future<void> shareGifBytes(Uint8List bytes, {String? subject}) async {
    final tempDir = await getTemporaryDirectory();
    final file = io.File('${tempDir.path}/chessever_game.gif');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: subject ?? 'ChessEver Game',
      sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
    );
  }

  /// Save GIF bytes to a user-chosen path.
  static Future<void> saveGifBytesToDisk(Uint8List bytes, {
    String defaultName = 'chessever_game.gif',
  }) async {
    String? outputPath;
    if (io.Platform.isMacOS || io.Platform.isWindows || io.Platform.isLinux) {
      outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Game GIF',
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: ['gif'],
      );
    }
    if (outputPath == null) {
      final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
      outputPath = '${dir.path}/$defaultName';
    }
    final file = io.File(outputPath);
    await file.writeAsBytes(bytes);
  }
}

/// A share-card preview widget used for screenshot capture.
///
/// Renders a clean board with optional metadata. Simpler than the mobile
/// share overlay — no 3D tilt, no eval bar, just the board + names.
class BoardShareCard extends StatelessWidget {
  const BoardShareCard({
    super.key,
    required this.fen,
    required this.boardSettings,
    this.lastMove,
    this.whiteName,
    this.blackName,
    this.event,
    this.result,
    this.boardSize = 320,
  });

  final String fen;
  final cg.ChessboardSettings boardSettings;
  final Move? lastMove;
  final String? whiteName;
  final String? blackName;
  final String? event;
  final String? result;
  final double boardSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: boardSize + 32,
      color: kBackgroundColor,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (event != null && event!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                event!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          cg.Chessboard.fixed(
            size: boardSize,
            settings: boardSettings.copyWith(animationDuration: Duration.zero),
            orientation: Side.white,
            fen: fen,
            lastMove: lastMove,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  whiteName ?? 'White',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'vs',
                  style: TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ),
              Flexible(
                child: Text(
                  blackName ?? 'Black',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (result != null && result!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                result!,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
