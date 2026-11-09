import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/screens/gamebase/providers/explorer_eval_provider.dart';

/// Live evaluation for one Play tab. Reuses the explorer's eval notifier
/// (gamebase / cloud / local Stockfish cascade) but keyed per tab, so a Play
/// game and the Opening Explorer never steal each other's position. It is
/// auto-disposed, so the analysis engine stops as soon as the bar is hidden
/// or the tab closes.
final playLiveEvalProvider = StateNotifierProvider.autoDispose
    .family<ExplorerEvalNotifier, ExplorerEvalState, String>(
      (ref, tabId) => ExplorerEvalNotifier(ref),
    );

/// Eval bar beside the Play board. Only mounted when the player turned on
/// "Eval bar while playing"; follows whatever position the board shows,
/// including reviewed earlier moves.
class PlayLiveEvalBar extends ConsumerStatefulWidget {
  const PlayLiveEvalBar({
    super.key,
    required this.tabId,
    required this.fen,
    required this.width,
    required this.height,
    required this.isFlipped,
  });

  final String tabId;
  final String fen;
  final double width;
  final double height;
  final bool isFlipped;

  @override
  ConsumerState<PlayLiveEvalBar> createState() => _PlayLiveEvalBarState();
}

String playEvalPositionKey(String fen) {
  final parts = fen.trim().split(RegExp(r'\s+'));
  if (parts.length < 4) return fen.trim();
  return parts.take(4).join(' ');
}

class _PlayLiveEvalBarState extends ConsumerState<PlayLiveEvalBar> {
  void _scheduleEvaluation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(playLiveEvalProvider(widget.tabId).notifier)
          .setEngineEnabled(enabled: true, fen: widget.fen, force: true);
    });
  }

  @override
  void initState() {
    super.initState();
    _scheduleEvaluation();
  }

  @override
  void didUpdateWidget(covariant PlayLiveEvalBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (playEvalPositionKey(widget.fen) != playEvalPositionKey(oldWidget.fen) ||
        widget.tabId != oldWidget.tabId) {
      _scheduleEvaluation();
    }
  }

  @override
  Widget build(BuildContext context) {
    final evalState = ref.watch(playLiveEvalProvider(widget.tabId));
    final currentKey = playEvalPositionKey(widget.fen);
    final isCurrent = currentKey == playEvalPositionKey(evalState.fen);
    return DesktopEvalBar(
      width: widget.width,
      height: widget.height,
      isFlipped: widget.isFlipped,
      evaluation: isCurrent ? evalState.evaluation : null,
      mate: isCurrent ? evalState.mate : null,
      isEvaluating: isCurrent ? evalState.isEvaluating : true,
      positionKey: currentKey,
      // Keep the previous reading on screen while the next position is
      // searched, so the bar glides between moves instead of blanking.
      retainWhileRetargeting: true,
    );
  }
}
