import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/board_share_service.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
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
    this.shareUrl,
  });

  final ChessGame chessGame;
  final Map<String, String> headers;
  final Position position;
  final Move? lastMove;
  final List<int> pointer;
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

  String get _pgn => exportGameToPgn(widget.chessGame);

  bool get _hasMoves => widget.chessGame.mainline.isNotEmpty;

  String? get _shareUrl {
    final url = widget.shareUrl?.trim();
    return url == null || url.isEmpty ? null : url;
  }

  Future<void> _shareImage() async {
    setState(() => _isCapturing = true);
    try {
      final settings =
          ref.read(boardSettingsProviderNew).valueOrNull ??
          const BoardSettingsNew();
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
      );
      final bytes = await BoardShareService.captureWidget(
        card,
        width: 352,
        height: 420,
        pixelRatio: 2.5,
      );
      if (bytes == null) throw Exception('Capture returned null');
      await BoardShareService.sharePngBytes(
        bytes,
        subject: '$_whiteName vs $_blackName',
      );
    } catch (e) {
      _showToast('Failed to share image', isError: true);
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _downloadImage() async {
    setState(() => _isCapturing = true);
    try {
      final settings =
          ref.read(boardSettingsProviderNew).valueOrNull ??
          const BoardSettingsNew();
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
      );
      final bytes = await BoardShareService.captureWidget(
        card,
        width: 352,
        height: 420,
        pixelRatio: 2.5,
      );
      if (bytes == null) throw Exception('Capture returned null');
      await BoardShareService.savePngBytesToDisk(
        bytes,
        defaultName:
            'chessever_${_sanitizeFilename('$_whiteName vs $_blackName')}.png',
      );
      _showToast('Image saved', isError: false);
    } catch (e) {
      _showToast('Failed to save image', isError: true);
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _shareGif() async {
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

      // Build frames by replaying mainline moves from the start.
      final frames = <({String fen, Move? lastMove})>[];
      final durations = <int>[];

      // Initial position
      frames.add((fen: widget.chessGame.startingFen, lastMove: null));
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
        final last =
            move is NormalMove
                ? NormalMove(from: move.from, to: move.to)
                : null;
        frames.add((fen: pos.fen, lastMove: last));
        // Faster for middle moves, slower at the end
        final isLast = i == widget.chessGame.mainline.length - 1;
        durations.add(isLast ? 160 : 50);
      }

      final gifBytes = await BoardShareService.generateGif(
        frames: frames,
        durationsCs: durations,
        boardSettings: boardSettings,
      );

      if (gifBytes == null) throw Exception('GIF generation returned null');
      await BoardShareService.shareGifBytes(
        gifBytes,
        subject: '$_whiteName vs $_blackName',
      );
    } catch (e) {
      _showToast('Failed to share GIF', isError: true);
    } finally {
      if (mounted) setState(() => _isGeneratingGif = false);
    }
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
              // Preview
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kDividerColor),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: cg.Chessboard.fixed(
                      size: 240,
                      settings: cg.ChessboardSettings(
                        enableCoordinates: true,
                        animationDuration: Duration.zero,
                        colorScheme: settings.colorScheme,
                        pieceAssets: settings.pieceAssets,
                        borderRadius: BorderRadius.zero,
                        boxShadow: const [],
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
              if (hasLink) _buildShareLinkBar(),
              const SizedBox(height: 16),
              // Actions
              if (_isCapturing || _isGeneratingGif)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: kPrimaryColor,
                      ),
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
                    children: [
                      _ActionChip(
                        icon: Icons.image_outlined,
                        label: 'Share Image',
                        onTap: _shareImage,
                      ),
                      _ActionChip(
                        icon: Icons.gif_box_outlined,
                        label: 'Share GIF',
                        onTap: _shareGif,
                      ),
                      _ActionChip(
                        icon: Icons.download_rounded,
                        label: 'Download Image',
                        onTap: _downloadImage,
                      ),
                      _ActionChip(
                        icon: Icons.copy_rounded,
                        label: 'Copy PGN',
                        onTap: _copyPgn,
                      ),
                    ],
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
  String? shareUrl,
}) {
  return showDialog(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder:
        (_) => BoardShareDialog(
          chessGame: chessGame,
          headers: headers,
          position: position,
          lastMove: lastMove,
          pointer: pointer,
          shareUrl: shareUrl,
        ),
  );
}
