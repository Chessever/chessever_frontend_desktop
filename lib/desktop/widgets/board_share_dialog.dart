import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/board_share_service.dart';
import 'package:chessever/desktop/services/cloudflare_gif_service.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';

const _defaultBoardShareShowEvalBar = false;

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
    this.showEvalBar = _defaultBoardShareShowEvalBar,
    this.liveBoardPngBytes,
    this.shareUrl,
    this.whiteFideId,
    this.blackFideId,
    this.whitePhotoUrl,
    this.blackPhotoUrl,
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

  /// One exact raster captured from the live Board pane. When supplied, both
  /// static-image actions export these same bytes rather than rebuilding a
  /// simplified share card.
  final Uint8List? liveBoardPngBytes;
  final String? shareUrl;
  final int? whiteFideId;
  final int? blackFideId;
  final String? whitePhotoUrl;
  final String? blackPhotoUrl;

  @override
  ConsumerState<BoardShareDialog> createState() => _BoardShareDialogState();
}

class _BoardShareDialogState extends ConsumerState<BoardShareDialog> {
  bool _isCapturing = false;
  bool _isGeneratingGif = false;
  bool _isSavingGif = false;
  String? _generatedGifPath;
  String _gifProgressLabel = 'Submitting…';
  late final BoardShareRaster _staticImage;

  @override
  void initState() {
    super.initState();
    _staticImage = BoardShareRaster(
      liveBoardPngBytes: widget.liveBoardPngBytes,
      fallbackCapture: _captureFallbackImageBytes,
    );
  }

  @override
  void dispose() {
    unawaited(_deleteTemporaryGif(_generatedGifPath));
    super.dispose();
  }

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
  int? get _whiteFideId => widget.whiteFideId ?? _headerInt('WhiteFideId');
  int? get _blackFideId => widget.blackFideId ?? _headerInt('BlackFideId');
  String? get _whiteScore => _scoreFor(isWhite: true);
  String? get _blackScore => _scoreFor(isWhite: false);
  String? get _shareUrl => boardShareVisibleUrl(widget.shareUrl);

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

  /// The Board pane supplies a real live capture. This renderer remains only
  /// for share entry points that do not have a mounted Board pane, and for the
  /// separately generated GIF frames below.
  Future<Uint8List> _captureFallbackImageBytes() async {
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
      final bytes = await _staticImage.bytes();
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
      final bytes = await _staticImage.bytes();
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

  Future<void> _generateGif() async {
    if (!_hasMoves) {
      _showToast('No moves to animate', isError: true);
      return;
    }
    setState(() {
      _isGeneratingGif = true;
      _gifProgressLabel = 'Submitting…';
    });
    CloudflareGifService? service;
    try {
      service = CloudflareGifService.fromDesktopEnvironment();
      if (mounted) {
        setState(() => _gifProgressLabel = 'Loading player photos…');
      }
      final photos = await _resolvePlayerPhotos();
      final photoData = await Future.wait([
        _cloudPhotoData(photos.whitePhotoUrl, playerLabel: 'white'),
        _cloudPhotoData(photos.blackPhotoUrl, playerLabel: 'black'),
      ]);
      if (mounted) {
        setState(() => _gifProgressLabel = 'Submitting…');
      }
      final job = await service.submitJob(
        pgn: _pgn,
        flipped: widget.flipped,
        metadata: <String, Object?>{
          'white': _whiteName,
          'black': _blackName,
          if (_whiteTitle.isNotEmpty) 'whiteTitle': _whiteTitle,
          if (_blackTitle.isNotEmpty) 'blackTitle': _blackTitle,
          if (_whiteRating != null) 'whiteRating': _whiteRating,
          if (_blackRating != null) 'blackRating': _blackRating,
          if (_whiteFederation.isNotEmpty) 'whiteFederation': _whiteFederation,
          if (_blackFederation.isNotEmpty) 'blackFederation': _blackFederation,
          if (photoData[0] != null) 'whitePhotoData': photoData[0],
          if (photoData[1] != null) 'blackPhotoData': photoData[1],
          if (_event.isNotEmpty) 'event': _event,
          if (_result.isNotEmpty) 'result': _result,
        },
      );
      debugPrint('Cloud GIF job submitted: ${job.id}');
      final completed = await service.waitUntilComplete(
        job.id,
        isCancelled: () => !mounted,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _gifProgressLabel = _gifProgressText(progress));
        },
      );
      if (!mounted) return;
      setState(() => _gifProgressLabel = 'Loading GIF preview…');
      final temporaryDirectory = await getTemporaryDirectory();
      final temporaryPath =
          '${temporaryDirectory.path}${io.Platform.pathSeparator}'
          'chessever_gif_preview_${DateTime.now().microsecondsSinceEpoch}.gif';
      await service.downloadToFile(
        jobId: completed.id,
        outputPath: temporaryPath,
      );
      if (!mounted) {
        await _deleteTemporaryGif(temporaryPath);
        return;
      }
      final previousPath = _generatedGifPath;
      setState(() => _generatedGifPath = temporaryPath);
      unawaited(_deleteTemporaryGif(previousPath));
      _showToast('GIF ready to preview', isError: false);
    } on CloudflareGifCancelled {
      // Closing the dialog only stops polling. The Workflow continues and the
      // deterministic request will resume when Share is opened again.
    } on CloudflareGifException catch (error) {
      debugPrint(
        'Cloud GIF failed: code=${error.code}, '
        'status=${error.statusCode ?? 'n/a'}, message=${error.message}',
      );
      _showToast('${error.message} [${error.code}]', isError: true);
    } catch (error, stackTrace) {
      debugPrint('Unexpected Cloud GIF failure: $error\n$stackTrace');
      _showToast(
        'Cloud GIF generation failed. [unexpected_client_error]',
        isError: true,
      );
    } finally {
      service?.close();
      if (mounted) setState(() => _isGeneratingGif = false);
    }
  }

  Future<void> _saveGeneratedGif() async {
    final generatedGifPath = _generatedGifPath;
    if (generatedGifPath == null) return;

    final outputPath = await BoardShareService.chooseGifSavePath(
      defaultName: _defaultExportName('gif'),
    );
    if (outputPath == null || !mounted) return;

    setState(() => _isSavingGif = true);
    try {
      await io.File(generatedGifPath).copy(outputPath);
      _showToast('GIF saved', isError: false);
    } catch (error, stackTrace) {
      debugPrint('Failed to save generated GIF: $error\n$stackTrace');
      _showToast('Failed to save GIF', isError: true);
    } finally {
      if (mounted) setState(() => _isSavingGif = false);
    }
  }

  Future<void> _deleteTemporaryGif(String? path) async {
    if (path == null) return;
    try {
      final file = io.File(path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Failed to remove temporary GIF preview: $error');
    }
  }

  Future<String?> _cloudPhotoData(
    String? photoUrl, {
    required String playerLabel,
  }) async {
    final uri = Uri.tryParse(photoUrl?.trim() ?? '');
    if (uri == null || uri.scheme != 'https') {
      debugPrint(
        'Cloud GIF $playerLabel photo omitted: no valid HTTPS photo URL.',
      );
      return null;
    }
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) {
          if (attempt == 1 && response.statusCode >= 500) {
            debugPrint(
              'Cloud GIF $playerLabel photo download returned '
              'HTTP ${response.statusCode}; retrying once.',
            );
            continue;
          }
          debugPrint(
            'Cloud GIF $playerLabel photo omitted: '
            'download returned HTTP ${response.statusCode}.',
          );
          return null;
        }
        if (response.bodyBytes.isEmpty) {
          debugPrint('Cloud GIF $playerLabel photo omitted: empty response.');
          return null;
        }
        if (response.bodyBytes.length > 512 * 1024) {
          debugPrint(
            'Cloud GIF $playerLabel photo omitted: '
            '${response.bodyBytes.length} bytes exceeds 512 KiB.',
          );
          return null;
        }
        final rawContentType =
            response.headers['content-type']?.split(';').first.trim() ?? '';
        final contentType = cloudGifPhotoMimeType(response.bodyBytes);
        if (contentType == null) {
          debugPrint(
            'Cloud GIF $playerLabel photo omitted: '
            'unsupported image bytes (response type: '
            '${rawContentType.isEmpty ? 'missing' : rawContentType}).',
          );
          return null;
        }
        debugPrint(
          'Cloud GIF $playerLabel photo attached: '
          '${response.bodyBytes.length} bytes, $contentType.',
        );
        return 'data:$contentType;base64,${base64Encode(response.bodyBytes)}';
      } catch (error) {
        if (attempt == 1) {
          debugPrint(
            'Cloud GIF $playerLabel photo download failed; retrying once: '
            '$error',
          );
          continue;
        }
        debugPrint('Cloud GIF $playerLabel photo unavailable: $error');
        return null;
      }
    }
    return null;
  }

  String _gifProgressText(CloudflareGifJob job) =>
      boardShareGifProgressText(job);

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
    Future<String?> photoFor(String? preferredUrl, int? fideId) async {
      final url =
          preferredUrl?.trim().isNotEmpty == true
              ? preferredUrl!.trim()
              : fideId == null || fideId <= 0
              ? null
              : await FidePhotoService.getPhotoUrlOrNull('$fideId');
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

    final urls = await Future.wait([
      photoFor(widget.whitePhotoUrl, _whiteFideId),
      photoFor(widget.blackPhotoUrl, _blackFideId),
    ]);
    return (whitePhotoUrl: urls[0], blackPhotoUrl: urls[1]);
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

  Future<void> _copyLink() async {
    final url = _shareUrl;
    if (url == null) {
      _showToast('No shareable link for this game', isError: true);
      return;
    }
    try {
      await BoardShareService.copyToClipboard(url);
      _showToast('Link copied to clipboard', isError: false);
    } catch (e) {
      _showToast('Failed to copy link', isError: true);
    }
  }

  Widget _buildShareLinkBar() {
    final url = _shareUrl;
    if (url == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: kBackgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBlack3Color),
        ),
        child: Row(
          children: [
            const Icon(Icons.link_rounded, size: 15, color: kWhiteColor70),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            DesktopDialogIconButton(
              icon: Icons.copy_rounded,
              tooltip: 'Copy link',
              tone: DesktopDialogButtonTone.secondary,
              onPress: _copyLink,
            ),
          ],
        ),
      ),
    );
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
    final hasLink = _shareUrl != null;
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
              // Preview the exact Board-pane raster whenever one was supplied.
              // Detached game/share entry points retain the lightweight static
              // preview because they have no mounted live board to capture.
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kDividerColor),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child:
                        _generatedGifPath != null
                            ? SizedBox(
                              width: 360,
                              height: 260,
                              child: Image.file(
                                io.File(_generatedGifPath!),
                                key: ValueKey<String>(
                                  'board-share-gif-preview:'
                                  '$_generatedGifPath',
                                ),
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.high,
                              ),
                            )
                            : widget.liveBoardPngBytes == null
                            ? cg.StaticChessboard(
                              size: 240,
                              settings: cg
                                  .StaticChessboardSettings.fromBoardSettings(
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
                            )
                            : SizedBox(
                              width: 360,
                              height: 260,
                              child: Image.memory(
                                widget.liveBoardPngBytes!,
                                key: const ValueKey<String>(
                                  'board-share-live-preview',
                                ),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                              ),
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
              if (hasLink) _buildShareLinkBar(),
              const SizedBox(height: 16),
              // Actions
              if (_isCapturing || _isGeneratingGif || _isSavingGif)
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
                              ? _gifProgressLabel
                              : _isSavingGif
                              ? 'Saving GIF…'
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
                        (_generatedGifPath == null
                                ? boardShareActionDescriptors(
                                  copyImage: _copyImage,
                                  generateGif: _generateGif,
                                  downloadImage: _downloadImage,
                                  copyPgn: _copyPgn,
                                )
                                : boardShareGeneratedGifActionDescriptors(
                                  downloadGif: _saveGeneratedGif,
                                ))
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

/// Holds the immutable source raster for a dialog session.
///
/// A Board pane capture is already the exact pixels the user saw, so it is
/// returned directly for both Copy Image and Download PNG. Non-live entry
/// points construct their fallback card at most once so those actions still
/// share one raster instead of recapturing independently.
@visibleForTesting
class BoardShareRaster {
  BoardShareRaster({
    required Uint8List? liveBoardPngBytes,
    required Future<Uint8List> Function() fallbackCapture,
  }) : _liveBoardPngBytes = liveBoardPngBytes,
       _fallbackCapture = fallbackCapture;

  final Uint8List? _liveBoardPngBytes;
  final Future<Uint8List> Function() _fallbackCapture;
  Future<Uint8List>? _fallbackBytes;

  Future<Uint8List> bytes() {
    final liveBoardPngBytes = _liveBoardPngBytes;
    if (liveBoardPngBytes != null) {
      return Future<Uint8List>.value(liveBoardPngBytes);
    }
    return _fallbackBytes ??= _fallbackCapture();
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
  required VoidCallback generateGif,
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
      label: 'Generate GIF',
      onTap: generateGif,
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

@visibleForTesting
List<BoardShareActionDescriptor> boardShareGeneratedGifActionDescriptors({
  required VoidCallback downloadGif,
}) {
  return [
    BoardShareActionDescriptor(
      icon: Icons.download_rounded,
      label: 'Download GIF',
      onTap: downloadGif,
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

@visibleForTesting
String? boardShareVisibleUrl(String? shareUrl) {
  final url = shareUrl?.trim();
  return url == null || url.isEmpty ? null : url;
}

@visibleForTesting
String? cloudGifPhotoMimeType(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
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

/// User-visible GIF job progress label. Must stay product-neutral (no vendor names).
@visibleForTesting
String boardShareGifProgressText(CloudflareGifJob job) {
  final frames =
      job.totalFrames > 0
          ? ' ${job.completedFrames.clamp(0, job.totalFrames)}/${job.totalFrames}'
          : '';
  return switch (job.stage) {
    CloudflareGifJobStatus.queued => 'Queued…',
    CloudflareGifJobStatus.analyzing => 'Analyzing positions$frames…',
    CloudflareGifJobStatus.rendering => 'Rendering frames$frames…',
    CloudflareGifJobStatus.encoding => 'Encoding GIF…',
    CloudflareGifJobStatus.storing => 'Finalizing GIF…',
    CloudflareGifJobStatus.succeeded => 'GIF ready',
    CloudflareGifJobStatus.failed => 'GIF generation failed',
  };
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
  bool showEvalBar = _defaultBoardShareShowEvalBar,
  Uint8List? liveBoardPngBytes,
  String? shareUrl,
  int? whiteFideId,
  int? blackFideId,
  String? whitePhotoUrl,
  String? blackPhotoUrl,
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
          liveBoardPngBytes: liveBoardPngBytes,
          shareUrl: shareUrl,
          whiteFideId: whiteFideId,
          blackFideId: blackFideId,
          whitePhotoUrl: whitePhotoUrl,
          blackPhotoUrl: blackPhotoUrl,
        ),
  );
}
