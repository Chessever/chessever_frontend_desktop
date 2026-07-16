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
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/widgets/gif_export_worker.dart';
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
    String? whiteTitle,
    String? blackTitle,
    int? whiteRating,
    int? blackRating,
    String? whiteFederation,
    String? blackFederation,
    String? whiteScore,
    String? blackScore,
    String? whitePhotoUrl,
    String? blackPhotoUrl,
    double? evaluation,
    int? mate,
    bool isEvaluating = false,
    bool showEvalBar = true,
    bool flipped = false,
    List<({String? whiteClock, String? blackClock})>? clocks,
    List<({double? evaluation, int? mate, bool isEvaluating})>?
    frameEvaluations,
  }) async {
    if (frames.isEmpty) return null;

    final rgbaFrames = <Uint8List>[];
    final widths = <int>[];
    final heights = <int>[];

    const boardSize = 400.0;
    const pixelRatio = 1.0;
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
      final frameEval =
          frameEvaluations != null && i < frameEvaluations.length
              ? frameEvaluations[i]
              : null;
      // Per-frame evals govern when the caller supplies [frameEvaluations]:
      // a null frame eval means "no eval for this position" and must render a
      // neutral bar — never borrow the single top-level [evaluation], which
      // belongs to one live position and would smear across the whole GIF.
      // The single top-level value only applies when no per-frame list exists.
      final double? resolvedEvaluation =
          frameEvaluations != null ? frameEval?.evaluation : evaluation;
      final int? resolvedMate =
          frameEvaluations != null ? frameEval?.mate : mate;
      final bool resolvedIsEvaluating =
          frameEvaluations != null
              ? (frameEval?.isEvaluating ?? false)
              : isEvaluating;
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
                whiteTitle: whiteTitle,
                blackTitle: blackTitle,
                whiteRating: whiteRating,
                blackRating: blackRating,
                whiteFederation: whiteFederation,
                blackFederation: blackFederation,
                whiteScore: whiteScore,
                blackScore: blackScore,
                whitePhotoUrl: whitePhotoUrl,
                blackPhotoUrl: blackPhotoUrl,
                sideToMove: _sideToMoveFromFen(frame.fen),
                flipped: flipped,
                boardSize: boardSize,
                evaluation: resolvedEvaluation,
                mate: resolvedMate,
                isEvaluating: resolvedIsEvaluating,
                showEvalBar: showEvalBar,
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
        width:
            includePlayerBars
                ? boardShareCardWidth(boardSize, showEvalBar: showEvalBar)
                : boardSize,
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
    final file = io.File(_ensureExtension(outputPath, 'gif'));
    await file.writeAsBytes(bytes);
  }
}

String _ensureExtension(String path, String extension) {
  final normalizedExtension =
      extension.startsWith('.') ? extension.toLowerCase() : '.$extension';
  return path.toLowerCase().endsWith(normalizedExtension)
      ? path
      : '$path$normalizedExtension';
}

/// Per-frame data for a shared board GIF, produced by replaying a game's
/// mainline from its starting position.
///
/// All four lists are the same length and index-aligned. Index 0 is the
/// starting position (no move played); indices 1..n follow each replayed ply.
class BoardShareGifFrames {
  const BoardShareGifFrames({
    required this.frames,
    required this.durationsCs,
    required this.clocks,
    required this.evaluations,
  });

  final List<({String fen, Move? lastMove})> frames;
  final List<int> durationsCs;
  final List<({String? whiteClock, String? blackClock})> clocks;
  final List<({double? evaluation, int? mate, bool isEvaluating})> evaluations;
}

typedef BoardShareFrameEvaluation =
    ({double? evaluation, int? mate, bool isEvaluating});

/// Fills missing replay evaluations without applying one position's score to
/// another. Requests are bounded so a miniature does not fire every lookup at
/// the backend simultaneously; failed/missing positions remain neutral.
Future<List<BoardShareFrameEvaluation>> hydrateBoardShareGifEvaluations({
  required List<({String fen, Move? lastMove})> frames,
  required List<BoardShareFrameEvaluation> evaluations,
  required Future<BoardShareFrameEvaluation?> Function(String fen)
  fetchEvaluation,
  Future<BoardShareFrameEvaluation?> Function(String fen)? fallbackEvaluation,
  int concurrency = 8,
}) async {
  final hydrated = <BoardShareFrameEvaluation>[
    for (var i = 0; i < frames.length; i++)
      i < evaluations.length
          ? evaluations[i]
          : (evaluation: null, mate: null, isEvaluating: false),
  ];
  final missing = <int>[
    for (var i = 0; i < hydrated.length; i++)
      if (hydrated[i].evaluation == null && hydrated[i].mate == null) i,
  ];
  final batchSize = concurrency.clamp(1, 16);

  for (var offset = 0; offset < missing.length; offset += batchSize) {
    final end = (offset + batchSize).clamp(0, missing.length);
    final batch = missing.sublist(offset, end);
    final fetched = await Future.wait(
      batch.map((index) async {
        try {
          return (
            index: index,
            evaluation: await fetchEvaluation(frames[index].fen),
          );
        } catch (_) {
          return (index: index, evaluation: null);
        }
      }),
    );
    for (final item in fetched) {
      final evaluation = item.evaluation;
      if (evaluation != null) hydrated[item.index] = evaluation;
    }
  }

  if (fallbackEvaluation != null) {
    for (var i = 0; i < hydrated.length; i++) {
      if (hydrated[i].evaluation != null || hydrated[i].mate != null) continue;
      final terminal = boardShareTerminalEvaluation(frames[i].fen);
      if (terminal != null) {
        hydrated[i] = terminal;
        continue;
      }
      try {
        final fallback = await fallbackEvaluation(frames[i].fen);
        if (fallback != null) hydrated[i] = fallback;
      } catch (_) {
        // Keep this individual frame neutral when both sources are unavailable.
      }
    }
  }

  return hydrated;
}

/// Converts a cloud PV to the white-perspective score expected by the share
/// eval bar. Some engines return side-to-move scores, so FEN turn matters.
BoardShareFrameEvaluation? boardShareEvaluationFromCloud(
  CloudEval? cloud,
  String fen,
) {
  if (cloud == null || cloud.pvs.isEmpty) return null;
  return boardShareEvaluationFromPv(cloud.pvs.first, fen);
}

BoardShareFrameEvaluation boardShareEvaluationFromPv(Pv pv, String fen) {
  var sign = 1;
  if (!pv.whitePerspective) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    sign = parts.length > 1 && parts[1] == 'b' ? -1 : 1;
  }
  if (pv.isMate || pv.mate != null) {
    final signedMate = pv.mate == null ? null : pv.mate! * sign;
    return (
      evaluation: (signedMate ?? pv.cp.sign * sign) >= 0 ? 10.0 : -10.0,
      mate: signedMate,
      isEvaluating: false,
    );
  }
  return (evaluation: (pv.cp * sign) / 100.0, mate: null, isEvaluating: false);
}

BoardShareFrameEvaluation? boardShareTerminalEvaluation(String fen) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    if (!position.isGameOver) return null;
    if (position.isCheckmate) {
      final whiteWon = position.turn == Side.black;
      return (
        evaluation: whiteWon ? 10.0 : -10.0,
        mate: whiteWon ? 1 : -1,
        isEvaluating: false,
      );
    }
    return (evaluation: 0.0, mate: null, isEvaluating: false);
  } catch (_) {
    return null;
  }
}

/// Parses a PGN `[%eval …]` payload into a share-frame evaluation record.
///
/// Accepts centipawn floats (`0.34`, `-1.2`) and mate strings (`#3`, `M-2`).
/// Returns null when the text is empty or unrecognised.
({double? evaluation, int? mate, bool isEvaluating})? parseBoardShareMoveEval(
  String? raw,
) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;
  final mateMatch = RegExp(
    r'^(?:#|M)([+-]?\d+)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (mateMatch != null) {
    final mate = int.tryParse(mateMatch.group(1)!);
    if (mate != null) {
      return (evaluation: null, mate: mate, isEvaluating: false);
    }
  }
  final cp = double.tryParse(text);
  if (cp == null) return null;
  return (evaluation: cp, mate: null, isEvaluating: false);
}

/// Replays [mainline] from [startingFen] to build every GIF frame together with
/// its last move (for board highlighting), running clocks, and evaluation.
///
/// The last move is captured for every ply so each frame highlights its own
/// from/to squares. Evaluations come solely from that move's PGN `[%eval]`
/// annotation. Unannotated frames remain null so export can hydrate their exact
/// positions instead of freezing at an earlier move's stale score.
///
/// Replay stops cleanly at the first SAN that cannot be parsed from the current
/// position rather than skipping it, which would desync every later frame.
BoardShareGifFrames buildBoardShareGifFrames({
  required String startingFen,
  required List<ChessMove> mainline,
  int initialHoldCs = 80,
  int moveHoldCs = 50,
  int finalHoldCs = 160,
}) {
  final frames = <({String fen, Move? lastMove})>[];
  final clocks = <({String? whiteClock, String? blackClock})>[];
  final evaluations = <({double? evaluation, int? mate, bool isEvaluating})>[];
  final durations = <int>[];

  String? whiteClock;
  String? blackClock;

  Position pos;
  try {
    pos = Chess.fromSetup(Setup.parseFen(startingFen));
  } catch (_) {
    pos = Chess.initial;
  }

  // Starting position: no move played yet, no eval known.
  frames.add((fen: pos.fen, lastMove: null));
  clocks.add((whiteClock: whiteClock, blackClock: blackClock));
  evaluations.add((evaluation: null, mate: null, isEvaluating: false));
  durations.add(initialHoldCs);

  for (var i = 0; i < mainline.length; i++) {
    final moveData = mainline[i];
    final move = pos.parseSan(moveData.san);
    if (move == null) break; // Replay diverged — stop rather than desync.
    pos = pos.play(move);

    final clockTime = moveData.clockTime?.trim();
    if (clockTime != null && clockTime.isNotEmpty) {
      if (moveData.turn == ChessColor.white) {
        whiteClock = clockTime;
      } else if (moveData.turn == ChessColor.black) {
        blackClock = clockTime;
      }
    }

    final moveEvaluation = parseBoardShareMoveEval(moveData.eval);

    final last =
        move is NormalMove ? NormalMove(from: move.from, to: move.to) : null;
    frames.add((fen: pos.fen, lastMove: last));
    clocks.add((whiteClock: whiteClock, blackClock: blackClock));
    evaluations.add(
      moveEvaluation ?? (evaluation: null, mate: null, isEvaluating: false),
    );
    durations.add(moveHoldCs);
  }

  // Hold the final position a little longer so shared GIFs land on it.
  if (durations.length > 1) {
    durations[durations.length - 1] = finalHoldCs;
  }

  return BoardShareGifFrames(
    frames: frames,
    durationsCs: durations,
    clocks: clocks,
    evaluations: evaluations,
  );
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
