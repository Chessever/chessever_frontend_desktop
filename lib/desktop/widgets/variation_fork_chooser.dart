import 'package:chessground/chessground.dart' show PieceAssets;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/figurine_notation.dart';

/// Continuation option offered at a variation fork.
class VariationForkOption {
  const VariationForkOption({
    required this.pointer,
    required this.label,
    required this.san,
    required this.previewLine,
    required this.isMainline,
    required this.variationOrder,
  });

  /// Pointer to jump to if the user picks this option.
  final ChessMovePointer pointer;

  /// Caption — `Mainline`, `Variation 1`, etc.
  final String label;

  /// SAN of the first move of the chosen continuation.
  final String san;

  /// Continuation rendered as a single PGN-style SAN string, capped at
  /// 10 full moves. Includes [san] as its first move.
  final String previewLine;

  final bool isMainline;
  final int variationOrder;
}

/// Detect a fork for a user-driven forward step from [current] to [next].
///
/// The tree can store two different PGN shapes:
/// - same-colour variations attached to [next], which are alternatives to
///   [next] and must be offered before entering it.
/// - opposite-colour variations attached to [current], which are continuations
///   after [current] and must be offered only after [current] is highlighted.
///
/// Returns the candidate continuations (mainline + each variation) when a
/// fork is found, or `null` when the step is unambiguous.
List<VariationForkOption>? resolveVariationForkOptions({
  required ChessGame game,
  ChessMovePointer? current,
  required ChessMovePointer next,
}) {
  if (next.isEmpty) return null;
  final nextAt = _lineAt(game, next);
  if (nextAt == null) return null;

  if (current != null && _isImmediateLineSuccessor(current, next)) {
    final currentAt = _lineAt(game, current);
    final currentOptions = _continuationOptionsAfterCurrent(
      currentAt: currentAt,
      current: current,
      nextAt: nextAt,
      next: next,
    );
    if (currentOptions != null) return currentOptions;
  }

  return _sameColourAlternativeOptionsAtNext(nextAt: nextAt, next: next);
}

List<VariationForkOption>? _continuationOptionsAfterCurrent({
  required _LineAt? currentAt,
  required ChessMovePointer current,
  required _LineAt nextAt,
  required ChessMovePointer next,
}) {
  if (currentAt == null) return null;
  final currentMove = currentAt.line[currentAt.index];
  final nextMove = nextAt.line[nextAt.index];
  final variations = currentMove.variations;
  if (variations == null || variations.isEmpty) return null;

  final continuationEntries = <({int index, ChessLine line})>[];
  for (var v = 0; v < variations.length; v++) {
    final variation = variations[v];
    if (variation.isEmpty) continue;
    if (variation.first.turn != nextMove.turn) continue;
    continuationEntries.add((index: v, line: variation));
  }
  if (continuationEntries.isEmpty) return null;

  return _buildOptions(
    mainlinePointer: next,
    mainlineTail: nextAt.line.sublist(nextAt.index),
    variations: continuationEntries,
    variationPointerFor:
        (variationIndex) => <int>[...current, variationIndex, 0],
  );
}

List<VariationForkOption>? _sameColourAlternativeOptionsAtNext({
  required _LineAt nextAt,
  required ChessMovePointer next,
}) {
  final move = nextAt.line[nextAt.index];
  final variations = move.variations;
  if (variations == null || variations.isEmpty) return null;

  final alternativeEntries = <({int index, ChessLine line})>[];
  for (var v = 0; v < variations.length; v++) {
    final variation = variations[v];
    if (variation.isEmpty) continue;
    if (variation.first.turn != move.turn) continue;
    alternativeEntries.add((index: v, line: variation));
  }
  if (alternativeEntries.isEmpty) return null;

  return _buildOptions(
    mainlinePointer: next,
    mainlineTail: nextAt.line.sublist(nextAt.index),
    variations: alternativeEntries,
    variationPointerFor: (variationIndex) => <int>[...next, variationIndex, 0],
  );
}

List<VariationForkOption>? _buildOptions({
  required ChessMovePointer mainlinePointer,
  required ChessLine mainlineTail,
  required List<({int index, ChessLine line})> variations,
  required ChessMovePointer Function(int variationIndex) variationPointerFor,
}) {
  if (mainlineTail.isEmpty || variations.isEmpty) return null;
  final move = mainlineTail.first;
  final options = <VariationForkOption>[
    VariationForkOption(
      pointer: List<int>.unmodifiable(mainlinePointer),
      label: 'Mainline',
      san: move.san,
      previewLine: _formatLineSan(mainlineTail),
      isMainline: true,
      variationOrder: 0,
    ),
  ];
  for (final entry in variations) {
    final variation = entry.line;
    final head = variation.first;
    final pointer = variationPointerFor(entry.index);
    options.add(
      VariationForkOption(
        pointer: List<int>.unmodifiable(pointer),
        label:
            variations.length == 1
                ? 'Variation'
                : 'Variation ${options.length}',
        san: head.san,
        previewLine: _formatLineSan(variation),
        isMainline: false,
        variationOrder: entry.index + 1,
      ),
    );
  }
  if (options.length < 2) return null;
  return List<VariationForkOption>.unmodifiable(options);
}

const int _maxPreviewFullMoves = 10;
const int _pliesPerFullMove = 2;

String _formatLineSan(List<ChessMove> moves) {
  final visibleMoves = moves.take(_maxPreviewFullMoves * _pliesPerFullMove);
  final buf = StringBuffer();
  var i = 0;
  for (final m in visibleMoves) {
    if (m.turn == ChessColor.white) {
      if (buf.isNotEmpty) buf.write(' ');
      buf.write('${m.num}.${m.san}');
    } else {
      if (i == 0) {
        buf.write('${m.num}... ${m.san}');
      } else {
        buf.write(' ${m.san}');
      }
    }
    i += 1;
  }
  return buf.toString();
}

/// Show the variation fork chooser as a modeless popup with the same
/// fade/lift/scale spring used by the inline move hover preview, so the
/// in-game-view chrome reads as a single motion language.
///
/// Returns the picked pointer, or `null` if the user dismissed without
/// choosing (Esc, barrier tap).
Future<ChessMovePointer?> showVariationForkChooser({
  required BuildContext context,
  required List<VariationForkOption> options,
  BuildContext? targetContext,
}) {
  final targetRect = notationSideChooserTargetRect(targetContext);
  return showGeneralDialog<ChessMovePointer>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: 'Variation chooser',
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder:
        (context, _, __) => _NotationSideChooserFrame(
          targetRect: targetRect,
          child: _ForkChooserDialog(options: options),
        ),
    transitionBuilder: (context, anim, __, child) {
      // Drive the same opacity + Y-lift + scale as MoveHoverPreview by
      // running motor's hover spring against the dialog's primary anim.
      return _ForkChooserMotion(animation: anim, child: child);
    },
  );
}

enum GameContinuationAction { insertMoves, openGame }

/// Show the same hover-styled chooser when a game-table continuation can be
/// either inserted into the current notation tree or opened as a full game.
Future<GameContinuationAction?> showGameContinuationActionChooser({
  required BuildContext context,
  required String previewLine,
  required int plyCount,
  required bool canInsertMoves,
  BuildContext? targetContext,
}) {
  final options = <_GameContinuationOption>[
    if (canInsertMoves)
      _GameContinuationOption(
        action: GameContinuationAction.insertMoves,
        label: 'Insert moves',
        detail: previewLine,
        icon: Icons.playlist_add_rounded,
      ),
    const _GameContinuationOption(
      action: GameContinuationAction.openGame,
      label: 'Open game',
      detail: 'Load the full game in a board tab',
      icon: Icons.open_in_new_rounded,
    ),
  ];
  final targetRect = notationSideChooserTargetRect(targetContext);
  return showGeneralDialog<GameContinuationAction>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: 'Game continuation action',
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder:
        (context, _, __) => _NotationSideChooserFrame(
          targetRect: targetRect,
          child: _GameContinuationActionDialog(
            options: options,
            plyCount: plyCount,
          ),
        ),
    transitionBuilder: (context, anim, __, child) {
      return _ForkChooserMotion(animation: anim, child: child);
    },
  );
}

class _GameContinuationOption {
  const _GameContinuationOption({
    required this.action,
    required this.label,
    required this.detail,
    required this.icon,
  });

  final GameContinuationAction action;
  final String label;
  final String detail;
  final IconData icon;
}

@visibleForTesting
const double notationSideChooserWidthFactor = 0.48;

@visibleForTesting
const EdgeInsets notationSideChooserPadding = EdgeInsets.fromLTRB(
  16,
  84,
  24,
  84,
);

@visibleForTesting
Rect? notationSideChooserTargetRect(BuildContext? targetContext) {
  if (targetContext == null) return null;
  final renderObject = targetContext.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return null;
  final topLeft = renderObject.localToGlobal(Offset.zero);
  return topLeft & renderObject.size;
}

class _NotationSideChooserFrame extends StatelessWidget {
  const _NotationSideChooserFrame({required this.child, this.targetRect});

  final Widget child;
  final Rect? targetRect;

  @override
  Widget build(BuildContext context) {
    final rect = targetRect;
    if (rect != null && rect.width > 0 && rect.height > 0) {
      return Stack(
        children: [
          Positioned(
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: notationSideChooserPadding,
                  child: child,
                ),
              ),
            ),
          ),
        ],
      );
    }
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: notationSideChooserWidthFactor,
          alignment: Alignment.centerRight,
          child: Padding(padding: notationSideChooserPadding, child: child),
        ),
      ),
    );
  }
}

class _ForkChooserMotion extends StatelessWidget {
  const _ForkChooserMotion({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        // Identical curve shape to MoveHoverPreview._AnimatedHoverCard.
        final scale = 0.94 + 0.06 * t;
        return Opacity(
          opacity: t.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 6),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}

class _GameContinuationActionDialog extends ConsumerStatefulWidget {
  const _GameContinuationActionDialog({
    required this.options,
    required this.plyCount,
  });

  final List<_GameContinuationOption> options;
  final int plyCount;

  @override
  ConsumerState<_GameContinuationActionDialog> createState() =>
      _GameContinuationActionDialogState();
}

class _GameContinuationActionDialogState
    extends ConsumerState<_GameContinuationActionDialog> {
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'game-continuation-action-chooser',
  );
  int _focused = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _pick(int index) {
    if (index < 0 || index >= widget.options.length) return;
    Navigator.of(
      context,
    ).pop<GameContinuationAction>(widget.options[index].action);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final total = widget.options.length;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _focused = (_focused + 1).clamp(0, total - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _focused = (_focused - 1).clamp(0, total - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _pick(_focused);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final num1 = LogicalKeyboardKey.digit1.keyId;
    final num9 = LogicalKeyboardKey.digit9.keyId;
    final id = key.keyId;
    if (id >= num1 && id <= num9) {
      final idx = id - num1;
      if (idx < total) _pick(idx);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final countLabel =
        widget.plyCount == 1 ? '1 move' : '${widget.plyCount} moves';
    return Center(
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, minWidth: 320),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.alt_route_rounded,
                        size: 14,
                        color: kPrimaryColor,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Use continuation…',
                        style: TextStyle(
                          color: kWhiteColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        countLabel,
                        style: const TextStyle(
                          color: kLightGreyColor,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < widget.options.length; i++) ...[
                    _GameContinuationOptionRow(
                      option: widget.options[i],
                      index: i,
                      selected: i == _focused,
                      onTap: () => _pick(i),
                      onHover: () => setState(() => _focused = i),
                    ),
                    if (i != widget.options.length - 1)
                      const SizedBox(height: 4),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: const [
                      _HintChip(label: '↑↓'),
                      SizedBox(width: 6),
                      _HintChip(label: '→'),
                      SizedBox(width: 6),
                      _HintChip(label: 'Esc'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GameContinuationOptionRow extends StatefulWidget {
  const _GameContinuationOptionRow({
    required this.option,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final _GameContinuationOption option;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  State<_GameContinuationOptionRow> createState() =>
      _GameContinuationOptionRowState();
}

class _GameContinuationOptionRowState
    extends State<_GameContinuationOptionRow> {
  @override
  Widget build(BuildContext context) {
    final rowFill =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.16)
            : kBlack3Color.withValues(alpha: 0.35);
    final border =
        widget.selected
            ? Border.all(color: kPrimaryColor.withValues(alpha: 0.55))
            : Border.all(color: kDividerColor);

    return SingleMotionBuilder(
      value: widget.selected ? 1.0 : 0.0,
      motion: DesktopMotion.hover,
      builder: (context, t, child) {
        final scale = 0.985 + 0.015 * t;
        return Transform.scale(scale: scale, child: child);
      },
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => widget.onHover(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              decoration: BoxDecoration(
                color: rowFill,
                borderRadius: BorderRadius.circular(7),
                border: border,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Center(
                      child:
                          widget.selected
                              ? const Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: kPrimaryColor,
                              )
                              : Text(
                                '${widget.index + 1}',
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Icon(widget.option.icon, size: 16, color: kPrimaryColor),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.option.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.option.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ForkChooserDialog extends ConsumerStatefulWidget {
  const _ForkChooserDialog({required this.options});

  final List<VariationForkOption> options;

  @override
  ConsumerState<_ForkChooserDialog> createState() => _ForkChooserDialogState();
}

class _ForkChooserDialogState extends ConsumerState<_ForkChooserDialog> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'variation-fork-chooser');
  int _focused = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _pick(int index) {
    if (index < 0 || index >= widget.options.length) return;
    Navigator.of(context).pop<ChessMovePointer>(widget.options[index].pointer);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final total = widget.options.length;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _focused = (_focused + 1).clamp(0, total - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _focused = (_focused - 1).clamp(0, total - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _pick(_focused);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _pick(_focused);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    // Number keys 1..9 pick directly.
    final num1 = LogicalKeyboardKey.digit1.keyId;
    final num9 = LogicalKeyboardKey.digit9.keyId;
    final id = key.keyId;
    if (id >= num1 && id <= num9) {
      final idx = id - num1;
      if (idx < total) _pick(idx);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      boardSettingsProviderNew.select(
        (s) => s.valueOrNull ?? const BoardSettingsNew(),
      ),
    );
    final pieceAssets = settings.pieceAssets;
    final useFigurine = settings.useFigurine;

    return Center(
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, minWidth: 340),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 28,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ForkChooserHeader(count: widget.options.length),
                  const SizedBox(height: 10),
                  for (var i = 0; i < widget.options.length; i++) ...[
                    _ForkOptionRow(
                      option: widget.options[i],
                      index: i,
                      selected: i == _focused,
                      useFigurine: useFigurine,
                      pieceAssets: pieceAssets,
                      onTap: () => _pick(i),
                      onHover: () => setState(() => _focused = i),
                    ),
                    if (i != widget.options.length - 1)
                      const SizedBox(height: 4),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: const [
                      _HintChip(label: '1–9'),
                      SizedBox(width: 6),
                      _HintChip(label: '↑↓'),
                      SizedBox(width: 6),
                      _HintChip(label: '↵'),
                      SizedBox(width: 6),
                      _HintChip(label: 'Esc'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ForkChooserHeader extends StatelessWidget {
  const _ForkChooserHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.34)),
            ),
            child: const Icon(
              Icons.alt_route_rounded,
              size: 12,
              color: kPrimaryColor,
            ),
          ),
          const SizedBox(width: 9),
          const Text(
            'Continue with',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDividerColor),
            ),
            child: Text(
              '$count lines',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForkOptionRow extends StatefulWidget {
  const _ForkOptionRow({
    required this.option,
    required this.index,
    required this.selected,
    required this.useFigurine,
    required this.pieceAssets,
    required this.onTap,
    required this.onHover,
  });

  final VariationForkOption option;
  final int index;
  final bool selected;
  final bool useFigurine;
  final PieceAssets pieceAssets;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  State<_ForkOptionRow> createState() => _ForkOptionRowState();
}

class _ForkOptionRowState extends State<_ForkOptionRow> {
  @override
  Widget build(BuildContext context) {
    final rowFill =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.13)
            : kBlack3Color.withValues(alpha: 0.28);
    final border =
        widget.selected
            ? Border.all(color: kPrimaryColor.withValues(alpha: 0.55))
            : Border.all(color: kDividerColor);
    final badgeFill =
        widget.selected ? kPrimaryColor : kBlack3Color.withValues(alpha: 0.9);
    final badgeFg = widget.selected ? kBlack2Color : kLightGreyColor;

    const sanStyle = TextStyle(
      color: kWhiteColor,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      fontFeatures: [FontFeature.tabularFigures()],
      height: 1.15,
    );

    return SingleMotionBuilder(
      value: widget.selected ? 1.0 : 0.0,
      motion: DesktopMotion.hover,
      builder: (context, t, child) {
        final scale = 0.99 + 0.01 * t;
        return Transform.scale(scale: scale, child: child);
      },
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => widget.onHover(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: rowFill,
                borderRadius: BorderRadius.circular(8),
                border: border,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: badgeFill,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '${widget.index + 1}',
                      style: TextStyle(
                        color: badgeFg,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        height: 1.0,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child:
                        widget.useFigurine
                            ? RichText(
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              text: TextSpan(
                                children: buildFigurineSpans(
                                  text: widget.option.previewLine,
                                  pieceAssets: widget.pieceAssets,
                                  style: sanStyle,
                                  pieceSize: 14,
                                ),
                              ),
                            )
                            : Text(
                              widget.option.previewLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: sanStyle,
                            ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HintChip extends StatelessWidget {
  const _HintChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LineAt {
  const _LineAt(this.line, this.index);
  final ChessLine line;
  final int index;
}

_LineAt? _lineAt(ChessGame game, ChessMovePointer pointer) {
  if (pointer.isEmpty) return null;
  ChessLine line = game.mainline;
  ChessMove? current;
  int lastIndex = -1;
  for (var i = 0; i < pointer.length; i++) {
    final index = pointer[i];
    if (i.isEven) {
      if (index >= line.length) return null;
      current = line[index];
      lastIndex = index;
    } else {
      if (current == null ||
          current.variations == null ||
          index >= current.variations!.length) {
        return null;
      }
      line = current.variations![index];
    }
  }
  if (current == null || lastIndex < 0) return null;
  return _LineAt(line, lastIndex);
}

bool _isImmediateLineSuccessor(
  ChessMovePointer current,
  ChessMovePointer next,
) {
  if (current.isEmpty || current.length != next.length) return false;
  for (var i = 0; i < current.length - 1; i++) {
    if (current[i] != next[i]) return false;
  }
  return next.last == current.last + 1;
}
