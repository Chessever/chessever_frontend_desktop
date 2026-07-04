import 'dart:typed_data';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/board_share_service.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop-suitable share dialog for the board pane.
///
/// Presents a compact preview of the current position plus a grid of
/// share actions. Works with plain [ChessGame] + headers — no mobile
/// [GamesTourModel] required.
class BoardShareDialog extends ConsumerStatefulWidget {
  const BoardShareDialog({
    super.key,
    required this.chessGame,
    required this.headers,
    required this.position,
    required this.lastMove,
    required this.pointer,
    required this.flipped,
    this.evaluation,
    this.mate,
    this.isEvaluating = false,
    this.showEvalBar = true,
    this.shareUrl,
  });

  final ChessGame chessGame;
  final Map<String, String> headers;
  final Position position;
  final Move? lastMove;
  final List<int> pointer;
  final bool flipped;
  final double? evaluation;
  final int? mate;
  final bool isEvaluating;
  final bool showEvalBar;
  final String? shareUrl;

  @override
  ConsumerState<BoardShareDialog> createState() => _BoardShareDialogState();
}

class _BoardShareDialogState extends ConsumerState<BoardShareDialog> {
  bool _isCapturing = false;
  bool _isGeneratingGif = false;

  String get _whiteName => widget.headers['White']?.trim() ?? 'White';
  String get _blackName => widget.headers['Black']?.trim() ?? 'Black';
  String get _event => boardShareDisplayEvent(widget.headers) ?? '';
  String get _result => widget.headers['Result']?.trim() ?? '';
  String get _whiteTitle => _header('WhiteTitle') ?? '';
  String get _blackTitle => _header('BlackTitle') ?? '';
  String get _whiteFederation =>
      _header('WhiteFed') ??
      _header('WhiteFederation') ??
      _header('WhiteCountry') ??
      '';
  String get _blackFederation =>
      _header('BlackFed') ??
      _header('BlackFederation') ??
      _header('BlackCountry') ??
      '';
  int? get _whiteRating => _headerInt('WhiteElo');
  int? get _blackRating => _headerInt('BlackElo');
  int? get _whiteFideId => _headerInt('WhiteFideId');
  int? get _blackFideId => _headerInt('BlackFideId');
  String? get _whiteScore => _scoreFor(isWhite: true);
  String? get _blackScore => _scoreFor(isWhite: false);

  String get _pgn => exportGameToPgn(widget.chessGame);

  String? _header(String key) {
    final value = widget.headers[key]?.trim();
    return value == null || value.isEmpty || value == '?' ? null : value;
  }

  int? _headerInt(String key) {
    final value = int.tryParse(_header(key) ?? '');
    return value == null || value <= 0 ? null : value;
  }

  String? _scoreFor({required bool isWhite}) {
    switch (_result) {
      case '1-0':
        return isWhite ? '1' : '0';
      case '0-1':
        return isWhite ? '0' : '1';
      case '1/2-1/2':
        return '½';
      default:
        return null;
    }
  }

  bool get _hasMoves => widget.chessGame.mainline.isNotEmpty;

  Future<Uint8List> _captureImageBytes() async {
    final settings =
        ref.read(boardSettingsProviderNew).valueOrNull ??
        const BoardSettingsNew();
    final photos = await _resolvePlayerPhotos();
    final card = BoardShareCard(
      fen: widget.position.fen,
      boardSettings: cg.ChessboardSettings(
        enableCoordinates: true,
        animationDuration: Duration.zero,
        colorScheme: settings.colorScheme,
        pieceAssets: settings.pieceAssets,
        borderRadius: BorderRadius.zero,
        boxShadow: const [],
      ),
      lastMove: widget.lastMove,
      whiteName: _whiteName,
      blackName: _blackName,
      event: _event,
      result: _result,
      whiteClock: _clockAtPointer().whiteClock,
      blackClock: _clockAtPointer().blackClock,
      whiteTitle: _whiteTitle,
      blackTitle: _blackTitle,
      whiteRating: _whiteRating,
      blackRating: _blackRating,
      whiteFederation: _whiteFederation,
      blackFederation: _blackFederation,
      whiteScore: _whiteScore,
      blackScore: _blackScore,
      whitePhotoUrl: photos.whitePhotoUrl,
      blackPhotoUrl: photos.blackPhotoUrl,
      sideToMove: widget.position.turn,
      flipped: widget.flipped,
      evaluation: widget.evaluation,
      mate: widget.mate,
      isEvaluating: widget.isEvaluating,
      showEvalBar: widget.showEvalBar,
    );
    final bytes = await BoardShareService.captureWidget(
      card,
      width: boardShareCardWidth(320, showEvalBar: widget.showEvalBar),
      height: boardShareCardHeight(boardSize: 320, event: null),
      pixelRatio: 2.5,
    );
    if (bytes == null) throw Exception('Capture returned null');
    return bytes;
  }

  Future<void> _copyImage() async {
    setState(() => _isCapturing = true);
    try {
      final bytes = await _captureImageBytes();
      await BoardShareService.copyPngBytesToClipboard(bytes);
      _showToast('Image copied', isError: false);
    } catch (e) {
      _showToast('Couldn’t copy image. Try Download PNG.', isError: true);
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _downloadImage() async {
    setState(() => _isCapturing = true);
    try {
      final bytes = await _captureImageBytes();
      await BoardShareService.savePngBytesToDisk(
        bytes,
        defaultName: _defaultExportName('png'),
      );
      _showToast('PNG saved', isError: false);
    } catch (e) {
      _showToast('Failed to save PNG', isError: true);
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _downloadGif() async {
    if (!_hasMoves) {
      _showToast('No moves to animate', isError: true);
      return;
    }
    setState(() => _isGeneratingGif = true);
    try {
      final settings =
          ref.read(boardSettingsProviderNew).valueOrNull ??
          const BoardSettingsNew();
      final boardSettings = cg.ChessboardSettings(
        enableCoordinates: true,
        animationDuration: Duration.zero,
        colorScheme: settings.colorScheme,
        pieceAssets: settings.pieceAssets,
        borderRadius: BorderRadius.zero,
        boxShadow: const [],
      );
      final photos = await _resolvePlayerPhotos();

      // Build frames by replaying mainline moves from the start.
      final frames = <({String fen, Move? lastMove})>[];
      final frameClocks = <({String? whiteClock, String? blackClock})>[];
      final frameEvaluations =
          <({double? evaluation, int? mate, bool isEvaluating})>[];
      final durations = <int>[];
      String? whiteClock;
      String? blackClock;
      ({double? evaluation, int? mate, bool isEvaluating})? lastEval;

      // Initial position
      frames.add((fen: widget.chessGame.startingFen, lastMove: null));
      frameClocks.add((whiteClock: whiteClock, blackClock: blackClock));
      frameEvaluations.add((
        evaluation: null,
        mate: null,
        isEvaluating: widget.isEvaluating,
      ));
      durations.add(80); // 0.8s initial hold

      Position pos;
      try {
        pos = Chess.fromSetup(Setup.parseFen(widget.chessGame.startingFen));
      } catch (_) {
        pos = Chess.initial;
      }

      for (int i = 0; i < widget.chessGame.mainline.length; i++) {
        final moveData = widget.chessGame.mainline[i];
        final move = pos.parseSan(moveData.san);
        if (move == null) continue;
        pos = pos.play(move);
        final clockTime = moveData.clockTime?.trim();
        if (clockTime != null && clockTime.isNotEmpty) {
          if (moveData.turn == ChessColor.white) {
            whiteClock = clockTime;
          } else if (moveData.turn == ChessColor.black) {
            blackClock = clockTime;
          }
        }
        lastEval = _parseMoveEval(moveData.eval) ?? lastEval;
        final last =
            move is NormalMove
                ? NormalMove(from: move.from, to: move.to)
                : null;
        frames.add((fen: pos.fen, lastMove: last));
        frameClocks.add((whiteClock: whiteClock, blackClock: blackClock));
        frameEvaluations.add(
          lastEval ??
              (evaluation: null, mate: null, isEvaluating: widget.isEvaluating),
        );
        // Faster for middle moves, slower at the end
        final isLast = i == widget.chessGame.mainline.length - 1;
        durations.add(isLast ? 160 : 50);
      }

      final gifBytes = await BoardShareService.generateGif(
        frames: frames,
        durationsCs: durations,
        boardSettings: boardSettings,
        whiteName: _whiteName,
        blackName: _blackName,
        event: _event,
        result: _result,
        whiteTitle: _whiteTitle,
        blackTitle: _blackTitle,
        whiteRating: _whiteRating,
        blackRating: _blackRating,
        whiteFederation: _whiteFederation,
        blackFederation: _blackFederation,
        whiteScore: _whiteScore,
        blackScore: _blackScore,
        whitePhotoUrl: photos.whitePhotoUrl,
        blackPhotoUrl: photos.blackPhotoUrl,
        evaluation: widget.evaluation,
        mate: widget.mate,
        isEvaluating: widget.isEvaluating,
        showEvalBar: widget.showEvalBar,
        flipped: widget.flipped,
        clocks: frameClocks,
        frameEvaluations: frameEvaluations,
      );

      if (gifBytes == null) throw Exception('GIF generation returned null');
      await BoardShareService.saveGifBytesToDisk(
        gifBytes,
        defaultName: _defaultExportName('gif'),
      );
      _showToast('GIF saved', isError: false);
    } catch (e) {
      _showToast('Failed to save GIF', isError: true);
    } finally {
      if (mounted) setState(() => _isGeneratingGif = false);
    }
  }

  ({double? evaluation, int? mate, bool isEvaluating})? _parseMoveEval(
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

  String _defaultExportName(String extension) {
    final date = _header('Date')?.replaceAll('.', '-');
    final parts = [
      'chessever',
      _sanitizeFilename('$_whiteName vs $_blackName'),
      if (date != null && date.isNotEmpty) _sanitizeFilename(date),
    ].where((part) => part.isNotEmpty).join('_');
    final normalizedExtension =
        extension.startsWith('.') ? extension.substring(1) : extension;
    return '$parts.$normalizedExtension';
  }

  ({String? whiteClock, String? blackClock}) _clockAtPointer() {
    final path = _pathForCurrentPointer();
    String? whiteClock;
    String? blackClock;
    for (var i = path.length - 1; i >= 0; i--) {
      final move = path[i];
      final clockTime = move.clockTime?.trim();
      if (clockTime == null || clockTime.isEmpty) continue;
      if (move.turn == ChessColor.white && whiteClock == null) {
        whiteClock = clockTime;
      } else if (move.turn == ChessColor.black && blackClock == null) {
        blackClock = clockTime;
      }
      if (whiteClock != null && blackClock != null) break;
    }
    return (whiteClock: whiteClock, blackClock: blackClock);
  }

  Future<({String? whitePhotoUrl, String? blackPhotoUrl})>
  _resolvePlayerPhotos() async {
    Future<String?> photoFor(int? fideId) async {
      if (fideId == null || fideId <= 0) return null;
      final url = await FidePhotoService.getPhotoUrlOrNull('$fideId');
      final trimmed = url?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      if (mounted) {
        try {
          await precacheImage(NetworkImage(trimmed), context);
        } catch (_) {
          // Keep exporting with initials when the photo cannot be warmed.
        }
      }
      return trimmed;
    }

    final whitePhotoUrl = await photoFor(_whiteFideId);
    final blackPhotoUrl = await photoFor(_blackFideId);
    return (whitePhotoUrl: whitePhotoUrl, blackPhotoUrl: blackPhotoUrl);
  }

  List<ChessMove> _pathForCurrentPointer() {
    final pointer = widget.pointer;
    final path = <ChessMove>[];
    if (pointer.isEmpty) return path;

    ChessLine? currentLine = widget.chessGame.mainline;
    ChessMove? currentMove;

    for (var i = 0; i < pointer.length; i++) {
      final index = pointer[i];
      if (i.isEven) {
        if (currentLine == null || index >= currentLine.length) break;
        path.addAll(currentLine.take(index + 1));
        currentMove = currentLine[index];
        if (i == pointer.length - 1) break;
      } else {
        if (currentMove == null ||
            currentMove.variations == null ||
            index >= currentMove.variations!.length) {
          break;
        }
        final variation = currentMove.variations![index];
        if (variation.isNotEmpty && variation.first.turn == currentMove.turn) {
          path.removeLast();
        }
        currentLine = variation;
      }
    }
    return path;
  }

  Future<void> _copyPgn() async {
    try {
      await BoardShareService.copyToClipboard(_pgn);
      _showToast('PGN copied to clipboard', isError: false);
    } catch (e) {
      _showToast('Failed to copy PGN', isError: true);
    }
  }

  void _showToast(String message, {required bool isError}) {
    if (!mounted) return;
    showDesktopToast(context, message, error: isError);
  }

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(boardSettingsProviderNew).valueOrNull ??
        const BoardSettingsNew();
    return FTheme(
      data: FThemes.zinc.dark,
      child: Center(
        child: Container(
          width: 420,
          constraints: const BoxConstraints(maxHeight: 640),
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kDividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  children: [
                    const Icon(
                      Icons.share_rounded,
                      color: kPrimaryColor,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Share Game',
                        style: TextStyle(
                          color: kWhiteColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    DesktopDialogIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Close',
                      onPress: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Preview
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kDividerColor),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: cg.StaticChessboard(
                      size: 240,
                      settings: cg.StaticChessboardSettings.fromBoardSettings(
                        cg.ChessboardSettings(
                          enableCoordinates: true,
                          animationDuration: Duration.zero,
                          colorScheme: settings.colorScheme,
                          pieceAssets: settings.pieceAssets,
                          borderRadius: BorderRadius.zero,
                          boxShadow: const [],
                        ),
                      ),
                      orientation: Side.white,
                      fen: widget.position.fen,
                      lastMove: widget.lastMove,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Meta
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    Text(
                      '$_whiteName  vs  $_blackName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_event.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          _event,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Actions
              if (_isCapturing || _isGeneratingGif)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: kPrimaryColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _isGeneratingGif
                              ? 'Generating GIF…'
                              : 'Preparing image…',
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children:
                        boardShareActionDescriptors(
                              copyImage: _copyImage,
                              downloadGif: _downloadGif,
                              downloadImage: _downloadImage,
                              copyPgn: _copyPgn,
                            )
                            .map(
                              (action) => _ActionChip(
                                icon: action.icon,
                                label: action.label,
                                onTap: action.onTap,
                              ),
                            )
                            .toList(),
                  ),
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class BoardShareActionDescriptor {
  const BoardShareActionDescriptor({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

@visibleForTesting
List<BoardShareActionDescriptor> boardShareActionDescriptors({
  required VoidCallback copyImage,
  required VoidCallback downloadGif,
  required VoidCallback downloadImage,
  required VoidCallback copyPgn,
}) {
  return [
    BoardShareActionDescriptor(
      icon: Icons.image_rounded,
      label: 'Copy Image',
      onTap: copyImage,
    ),
    BoardShareActionDescriptor(
      icon: Icons.gif_box_outlined,
      label: 'Download GIF',
      onTap: downloadGif,
    ),
    BoardShareActionDescriptor(
      icon: Icons.download_rounded,
      label: 'Download PNG',
      onTap: downloadImage,
    ),
    BoardShareActionDescriptor(
      icon: Icons.copy_rounded,
      label: 'Copy PGN',
      onTap: copyPgn,
    ),
  ];
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DesktopDialogButton(label: label, icon: icon, onPress: onTap);
  }
}

String _sanitizeFilename(String input) {
  return input
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
}

@visibleForTesting
String? boardShareDisplayEvent(Map<String, String> headers) {
  String? header(String key) {
    final value = headers[key]?.trim();
    if (value == null || value.isEmpty || value == '?') return null;
    return value;
  }

  return header('BroadcastName') ??
      header('Broadcast Name') ??
      header('GroupBroadcastName') ??
      header('Group Broadcast Name') ??
      header('Event');
}

/// Show the desktop share dialog.
Future<void> showBoardShareDialog(
  BuildContext context, {
  required ChessGame chessGame,
  required Map<String, String> headers,
  required Position position,
  required Move? lastMove,
  required List<int> pointer,
  required bool flipped,
  double? evaluation,
  int? mate,
  bool isEvaluating = false,
  bool showEvalBar = true,
  String? shareUrl,
}) {
  return showDesktopDialog<void>(
    context,
    builder:
        (_) => BoardShareDialog(
          chessGame: chessGame,
          headers: headers,
          position: position,
          lastMove: lastMove,
          pointer: pointer,
          flipped: flipped,
          evaluation: evaluation,
          mate: mate,
          isEvaluating: isEvaluating,
          showEvalBar: showEvalBar,
          shareUrl: shareUrl,
        ),
  );
}
