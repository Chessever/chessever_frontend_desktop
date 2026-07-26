import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/pgn_clock_utils.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

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
    final file = io.File(_ensureExtension(outputPath, 'png'));
    await file.writeAsBytes(bytes);
  }

  /// Copy [text] to the system clipboard and optionally show a toast.
  static Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Copy PNG bytes to the system clipboard.
  static Future<void> copyPngBytesToClipboard(Uint8List bytes) async {
    if (io.Platform.isLinux) {
      await _copyPngBytesToLinuxClipboard(bytes);
      return;
    }
    await Pasteboard.writeImage(bytes);
  }

  static Future<void> _copyPngBytesToLinuxClipboard(Uint8List bytes) async {
    Future<bool> hasCommand(String command) async {
      final result = await io.Process.run('which', [command]);
      return result.exitCode == 0;
    }

    if (await hasCommand('wl-copy')) {
      final process = await io.Process.start('wl-copy', [
        '--type',
        'image/png',
      ]);
      process.stdin.add(bytes);
      await process.stdin.close();
      final exitCode = await process.exitCode;
      if (exitCode == 0) return;
    }

    if (await hasCommand('xclip')) {
      final process = await io.Process.start('xclip', [
        '-selection',
        'clipboard',
        '-t',
        'image/png',
        '-i',
      ]);
      process.stdin.add(bytes);
      await process.stdin.close();
      final exitCode = await process.exitCode;
      if (exitCode == 0) return;
    }

    throw UnsupportedError(
      'Image clipboard requires wl-copy or xclip on Linux',
    );
  }

  /// Pick the destination used by a cloud-generated GIF download.
  ///
  /// This does not buffer or write the GIF. The Cloudflare client streams the
  /// authenticated response to the returned path.
  static Future<String?> chooseGifSavePath({
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
    if (outputPath == null) return null;
    return _ensureExtension(outputPath, 'gif');
  }
}

String _ensureExtension(String path, String extension) {
  final normalizedExtension =
      extension.startsWith('.') ? extension.toLowerCase() : '.$extension';
  return path.toLowerCase().endsWith(normalizedExtension)
      ? path
      : '$path$normalizedExtension';
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
    this.whitePhotoUrl,
    this.blackPhotoUrl,
    this.sideToMove,
    this.flipped = false,
    this.boardSize = 320,
    this.evaluation,
    this.mate,
    this.isEvaluating = false,
    this.showEvalBar = true,
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
  final String? whitePhotoUrl;
  final String? blackPhotoUrl;
  final Side? sideToMove;
  final bool flipped;
  final double boardSize;
  final double? evaluation;
  final int? mate;
  final bool isEvaluating;
  final bool showEvalBar;

  static const double _evalBarWidth = 24.0;
  static const double _evalBarGap = 12.0;

  @override
  Widget build(BuildContext context) {
    final topIsWhite = flipped;
    final bottomIsWhite = !flipped;
    final orientation = flipped ? Side.black : Side.white;
    return Container(
      width: boardShareCardWidth(boardSize, showEvalBar: showEvalBar),
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
            photoUrl: topIsWhite ? whitePhotoUrl : blackPhotoUrl,
            isToMove: sideToMove == (topIsWhite ? Side.white : Side.black),
          ),
          Row(
            children: [
              if (showEvalBar) ...[
                SizedBox(
                  width: _evalBarWidth,
                  height: boardSize,
                  child: DesktopEvalBar(
                    width: _evalBarWidth,
                    height: boardSize,
                    isFlipped: flipped,
                    evaluation: evaluation,
                    mate: mate,
                    isEvaluating: isEvaluating,
                    positionKey: fen,
                  ),
                ),
                const SizedBox(width: _evalBarGap),
              ],
              cg.StaticChessboard(
                size: boardSize,
                settings: cg.StaticChessboardSettings.fromBoardSettings(
                  boardSettings.copyWith(animationDuration: Duration.zero),
                ),
                orientation: orientation,
                fen: fen,
                lastMove: lastMove,
              ),
            ],
          ),
          _BoardSharePlayerBar(
            name:
                bottomIsWhite ? (whiteName ?? 'White') : (blackName ?? 'Black'),
            title: bottomIsWhite ? whiteTitle : blackTitle,
            rating: bottomIsWhite ? whiteRating : blackRating,
            federation: bottomIsWhite ? whiteFederation : blackFederation,
            score: bottomIsWhite ? whiteScore : blackScore,
            clock: bottomIsWhite ? whiteClock : blackClock,
            photoUrl: bottomIsWhite ? whitePhotoUrl : blackPhotoUrl,
            isToMove: sideToMove == (bottomIsWhite ? Side.white : Side.black),
          ),
        ],
      ),
    );
  }
}

double boardShareCardWidth(double boardSize, {bool showEvalBar = true}) {
  return boardSize +
      (showEvalBar
          ? BoardShareCard._evalBarWidth + BoardShareCard._evalBarGap
          : 0);
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
    this.photoUrl,
    this.isToMove = false,
  });

  final String name;
  final String? title;
  final int? rating;
  final String? federation;
  final String? score;
  final String? clock;
  final String? photoUrl;
  final bool isToMove;

  @override
  Widget build(BuildContext context) {
    final clockText = formatPgnClockForDisplay(clock ?? '');
    final titleText = title?.trim();
    final ratingValue = rating ?? 0;
    final hasPhoto = photoUrl?.trim().isNotEmpty == true;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border.symmetric(
          horizontal: BorderSide(
            color: kWhiteColor.withValues(alpha: 0.10),
            width: 0.75,
          ),
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
                height: 1,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (hasPhoto) ...[
            Container(
              width: 42,
              height: 42,
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: kWhiteColor.withValues(alpha: 0.24)),
              ),
              child: PlayerInitialsAvatarCompact(
                photoUrl: photoUrl!.trim(),
                initials: _playerInitials(name),
                size: 40,
                borderRadius: 6,
              ),
            ),
            const SizedBox(width: 8),
          ],
          FederationFlag(
            federation: federation,
            width: 22,
            height: 16,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(width: 8),
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
          if (clockText.isNotEmpty) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color:
                    isToMove
                        ? kPrimaryColor.withValues(alpha: 0.18)
                        : kBlack2Color,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: isToMove ? kPrimaryColor : Colors.transparent,
                ),
                boxShadow:
                    isToMove
                        ? [
                          BoxShadow(
                            color: kPrimaryColor.withValues(alpha: 0.18),
                            blurRadius: 6,
                            offset: const Offset(0, 1),
                          ),
                        ]
                        : null,
              ),
              child: Text(
                clockText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isToMove ? kWhiteColor : kWhiteColor70,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                  height: 1,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _playerInitials(String name) {
  final parts =
      name
          .replaceAll(',', ' ')
          .split(RegExp(r'\s+'))
          .where((part) => part.isNotEmpty)
          .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final only = parts.first;
    return only.substring(0, only.length < 2 ? only.length : 2).toUpperCase();
  }
  return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
      .toUpperCase();
}
