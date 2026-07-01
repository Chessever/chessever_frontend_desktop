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
  static Future<Uint8List?> captureWidget(
    Widget widget, {
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
          child: SizedBox(width: width, height: height, child: widget),
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
  static Future<void> savePngBytesToDisk(
    Uint8List bytes, {
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
      final dir =
          await getDownloadsDirectory() ?? await getTemporaryDirectory();
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
    String? whiteName,
    String? blackName,
    String? event,
    String? result,
    bool flipped = false,
    List<({String? whiteClock, String? blackClock})>? clocks,
  }) async {
    if (frames.isEmpty) return null;

    final rgbaFrames = <Uint8List>[];
    final widths = <int>[];
    final heights = <int>[];

    const boardSize = 400.0;
    const cardWidth = boardSize;
    const pixelRatio = 1.5;
    final includePlayerBars =
        whiteName != null ||
        blackName != null ||
        (event != null && event.isNotEmpty);
    final cardHeight =
        includePlayerBars
            ? boardShareCardHeight(boardSize: boardSize, event: event)
            : boardSize;

    for (int i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final clock = clocks != null && i < clocks.length ? clocks[i] : null;
      final Widget board =
          includePlayerBars
              ? BoardShareCard(
                fen: frame.fen,
                boardSettings: boardSettings,
                lastMove: frame.lastMove,
                whiteName: whiteName,
                blackName: blackName,
                event: event,
                result: result,
                whiteClock: clock?.whiteClock,
                blackClock: clock?.blackClock,
                sideToMove: _sideToMoveFromFen(frame.fen),
                flipped: flipped,
                boardSize: boardSize,
              )
              : cg.StaticChessboard(
                size: boardSize,
                settings: cg.StaticChessboardSettings.fromBoardSettings(
                  boardSettings.copyWith(animationDuration: Duration.zero),
                ),
                orientation: Side.white,
                fen: frame.fen,
                lastMove: frame.lastMove,
              );

      final bytes = await captureWidget(
        board,
        width: includePlayerBars ? cardWidth : boardSize,
        height: cardHeight,
        pixelRatio: pixelRatio,
      );
      if (bytes == null) continue;

      // Decode PNG to raw RGBA for the GIF encoder
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      final image = frameInfo.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
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
  static Future<void> saveGifBytesToDisk(
    Uint8List bytes, {
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
      final dir =
          await getDownloadsDirectory() ?? await getTemporaryDirectory();
      outputPath = '${dir.path}/$defaultName';
    }
    final file = io.File(outputPath);
    await file.writeAsBytes(bytes);
  }
}

Side? _sideToMoveFromFen(String fen) {
  final parts = fen.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return null;
  return parts[1] == 'w'
      ? Side.white
      : parts[1] == 'b'
      ? Side.black
      : null;
}

/// A share-card preview widget used for screenshot capture.
///
/// Renders the board-image export as a clean copy of the board area: player
/// bars + board, with interactive focus/resize/tool icons omitted.
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
    this.whiteClock,
    this.blackClock,
    this.whiteTitle,
    this.blackTitle,
    this.whiteRating,
    this.blackRating,
    this.whiteFederation,
    this.blackFederation,
    this.whiteScore,
    this.blackScore,
    this.sideToMove,
    this.flipped = false,
    this.boardSize = 320,
  });

  final String fen;
  final cg.ChessboardSettings boardSettings;
  final Move? lastMove;
  final String? whiteName;
  final String? blackName;
  final String? event;
  final String? result;
  final String? whiteClock;
  final String? blackClock;
  final String? whiteTitle;
  final String? blackTitle;
  final int? whiteRating;
  final int? blackRating;
  final String? whiteFederation;
  final String? blackFederation;
  final String? whiteScore;
  final String? blackScore;
  final Side? sideToMove;
  final bool flipped;
  final double boardSize;

  @override
  Widget build(BuildContext context) {
    final topIsWhite = flipped;
    final bottomIsWhite = !flipped;
    final orientation = flipped ? Side.black : Side.white;
    return Container(
      width: boardSize,
      height: boardShareCardHeight(boardSize: boardSize, event: null),
      color: kBackgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BoardSharePlayerBar(
            name: topIsWhite ? (whiteName ?? 'White') : (blackName ?? 'Black'),
            title: topIsWhite ? whiteTitle : blackTitle,
            rating: topIsWhite ? whiteRating : blackRating,
            federation: topIsWhite ? whiteFederation : blackFederation,
            score: topIsWhite ? whiteScore : blackScore,
            clock: topIsWhite ? whiteClock : blackClock,
            isToMove: sideToMove == (topIsWhite ? Side.white : Side.black),
          ),
          cg.StaticChessboard(
            size: boardSize,
            settings: cg.StaticChessboardSettings.fromBoardSettings(
              boardSettings.copyWith(animationDuration: Duration.zero),
            ),
            orientation: orientation,
            fen: fen,
            lastMove: lastMove,
          ),
          _BoardSharePlayerBar(
            name:
                bottomIsWhite ? (whiteName ?? 'White') : (blackName ?? 'Black'),
            title: bottomIsWhite ? whiteTitle : blackTitle,
            rating: bottomIsWhite ? whiteRating : blackRating,
            federation: bottomIsWhite ? whiteFederation : blackFederation,
            score: bottomIsWhite ? whiteScore : blackScore,
            clock: bottomIsWhite ? whiteClock : blackClock,
            isToMove: sideToMove == (bottomIsWhite ? Side.white : Side.black),
          ),
        ],
      ),
    );
  }
}

double boardShareCardHeight({required double boardSize, String? event}) {
  return boardSize + 96;
}

class _BoardSharePlayerBar extends StatelessWidget {
  const _BoardSharePlayerBar({
    required this.name,
    this.title,
    this.rating,
    this.federation,
    this.score,
    this.clock,
    this.isToMove = false,
  });

  final String name;
  final String? title;
  final int? rating;
  final String? federation;
  final String? score;
  final String? clock;
  final bool isToMove;

  @override
  Widget build(BuildContext context) {
    final clockText = clock?.trim();
    final fedText = _flagEmoji(federation);
    final titleText = title?.trim();
    final ratingValue = rating ?? 0;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border.symmetric(
          horizontal: BorderSide(color: kWhiteColor.withValues(alpha: 0.10)),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              score?.trim().isNotEmpty == true ? score!.trim() : '',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (fedText != null) ...[
            Text(fedText, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
          ],
          if (titleText != null && titleText.isNotEmpty) ...[
            Text(
              titleText,
              style: const TextStyle(
                color: kPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (ratingValue > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$ratingValue',
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (clockText != null && clockText.isNotEmpty) ...[
            const SizedBox(width: 10),
            Container(
              constraints: const BoxConstraints(minWidth: 58),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color:
                    isToMove
                        ? kPrimaryColor.withValues(alpha: 0.36)
                        : kBlack3Color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color:
                      isToMove
                          ? kPrimaryColor
                          : kWhiteColor.withValues(alpha: 0.10),
                ),
              ),
              child: Text(
                clockText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String? _flagEmoji(String? raw) {
  final code = raw?.trim().toUpperCase();
  if (code == null ||
      code.length != 2 ||
      !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
    return null;
  }
  const base = 0x1F1E6;
  return String.fromCharCodes(code.codeUnits.map((unit) => base + unit - 65));
}
