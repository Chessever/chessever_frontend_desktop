import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/theme/app_theme.dart';

/// Hover-driven mini board popup attached to an inline notation token.
///
/// Wraps a clickable / hoverable child (typically a SAN token in a
/// continuation line or PV) and shows a small board floating above it
/// while the pointer hovers. The popup is rendered through the global
/// [Overlay] so it can escape tightly-clipped row containers (the
/// continuation subline sits inside an ellipsis-clipped Text, etc.).
///
/// The position is computed by replaying the supplied UCI line on the
/// supplied starting FEN. Animation uses motor's [DesktopMotion.hover]
/// for the fade/scale entry so the popup feels like everything else in
/// the desktop chrome (sidebar nudge, segment-tab arrival, etc.).
enum MoveHoverPreviewPlacement { tokenAnchored, engineLine }

class MoveHoverPreview extends StatefulWidget {
  const MoveHoverPreview({
    super.key,
    required this.startingFen,
    required this.movesUpToHover,
    required this.child,
    this.size = 220,
    this.orientation = Side.white,
    this.enabled = true,
    this.lastMoveUci,
    this.placement = MoveHoverPreviewPlacement.tokenAnchored,
    this.placementAnchorKey,
  });

  /// FEN to start replay from. The popup renders the position reached by
  /// playing [movesUpToHover] from this FEN.
  final String startingFen;

  /// UCI moves played from [startingFen] up to (and including) the move
  /// the user is hovering over. Pass an empty list for the starting
  /// position. Illegal / unparseable moves stop replay at that point.
  final List<String> movesUpToHover;

  /// Optional UCI of the move that produced [startingFen]. Used to paint
  /// from/to highlights on the popup when [startingFen] is already the
  /// post-move position (so [movesUpToHover] is empty). Ignored when
  /// [movesUpToHover] is non-empty (replay derives lastMove itself).
  final String? lastMoveUci;

  /// The token / widget the user hovers over.
  final Widget child;

  /// Side of the popup board.
  final double size;

  /// Orientation of the popup board.
  final Side orientation;

  /// When false, the popup is disabled (the child is rendered as-is).
  final bool enabled;

  /// How the popup is placed. Engine PVs use [engineLine] so nearby moves
  /// share a stable, clamped board location instead of anchoring directly
  /// above the move text.
  final MoveHoverPreviewPlacement placement;

  /// Optional render anchor used by [MoveHoverPreviewPlacement.engineLine].
  /// Pass a key for the whole PV line so moving between moves updates only
  /// the board content while the preview location stays fixed.
  final GlobalKey? placementAnchorKey;

  @override
  State<MoveHoverPreview> createState() => _MoveHoverPreviewState();
}

class _MoveHoverPreviewState extends State<MoveHoverPreview> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  bool _popupRefreshScheduled = false;
  bool _popupVisibilityScheduled = false;
  bool _hovered = false;

  @override
  void dispose() {
    _hovered = false;
    _removePopupNow();
    super.dispose();
  }

  void _showPopupNow() {
    if (_entry != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _entry = OverlayEntry(
      builder: (context) {
        final replay = _computeReplay();
        return _MoveHoverPopup(
          link: _link,
          placement: widget.placement,
          placementAnchorKey: widget.placementAnchorKey,
          size: widget.size,
          fen: replay.fen,
          preFen: replay.preFen,
          lastMove: replay.lastMove,
          orientation: widget.orientation,
        );
      },
    );
    overlay.insert(_entry!);
  }

  void _removePopupNow() {
    _entry?.remove();
    _entry = null;
  }

  void _schedulePopupVisibilitySync() {
    if (_popupVisibilityScheduled) return;
    _popupVisibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _popupVisibilityScheduled = false;
      if (!mounted) {
        _removePopupNow();
        return;
      }
      if (!widget.enabled || !_hovered) {
        _removePopupNow();
        return;
      }
      _showPopupNow();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _schedulePopupRefresh() {
    if (_entry == null || _popupRefreshScheduled) return;
    _popupRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _popupRefreshScheduled = false;
      final entry = _entry;
      if (!mounted || entry == null || !entry.mounted) return;
      entry.markNeedsBuild();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  ({String fen, String? preFen, Move? lastMove}) _computeReplay() {
    Position position;
    try {
      position = Chess.fromSetup(
        Setup.parseFen(widget.startingFen),
        ignoreImpossibleCheck: true,
      );
    } catch (_) {
      final fallbackLast =
          widget.movesUpToHover.isEmpty
              ? Move.parse(widget.lastMoveUci ?? '')
              : null;
      return (
        fen: widget.startingFen,
        preFen:
            fallbackLast == null
                ? null
                : _reverseToPreMoveFen(widget.startingFen, fallbackLast),
        lastMove: fallbackLast,
      );
    }
    Move? last;
    Position? prePosition;
    for (final uci in widget.movesUpToHover) {
      final move = Move.parse(uci);
      if (move == null) break;
      if (!position.isLegal(move)) break;
      prePosition = position;
      position = position.playUnchecked(move);
      last = move;
    }
    String? preFen;
    if (last != null && prePosition != null) {
      preFen = prePosition.fen;
    } else if (last == null && widget.lastMoveUci != null) {
      last = Move.parse(widget.lastMoveUci!);
      if (last != null) {
        preFen = _reverseToPreMoveFen(position.fen, last);
      }
    }
    return (fen: position.fen, preFen: preFen, lastMove: last);
  }

  @override
  void didUpdateWidget(covariant MoveHoverPreview old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled) {
      _schedulePopupVisibilitySync();
    } else if (_entry != null) {
      // Recompute on every update — the hovered token in a row can be
      // replaced by Flutter without firing onExit when the row rebuilds
      // around the cursor. Marking the entry dirty redraws the popup
      // with the fresh FEN. The call must be deferred: PV rows can rebuild
      // from inside a LayoutBuilder pass, and OverlayEntry.markNeedsBuild()
      // is a setState on the overlay subtree.
      _schedulePopupRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) {
          if (!widget.enabled) return;
          _hovered = true;
          _schedulePopupVisibilitySync();
        },
        onExit: (_) {
          _hovered = false;
          _schedulePopupVisibilitySync();
        },
        child: widget.child,
      ),
    );
  }
}

class _MoveHoverPopup extends ConsumerWidget {
  const _MoveHoverPopup({
    required this.link,
    required this.placement,
    required this.placementAnchorKey,
    required this.size,
    required this.fen,
    required this.preFen,
    required this.lastMove,
    required this.orientation,
  });

  final LayerLink link;
  final MoveHoverPreviewPlacement placement;
  final GlobalKey? placementAnchorKey;
  final double size;
  final String fen;
  final String? preFen;
  final Move? lastMove;
  final Side orientation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardSize = Size(size + 12, size + 12);
    final card = _AnimatedHoverCard(
      size: size,
      fen: fen,
      preFen: preFen,
      lastMove: lastMove,
      orientation: orientation,
    );

    if (placement == MoveHoverPreviewPlacement.engineLine) {
      return Positioned.fill(
        child: IgnorePointer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final anchorRect = _anchorRect(context) ?? Rect.zero;
              final origin = clampedHoverPreviewOrigin(
                anchorRect: anchorRect,
                overlaySize: constraints.biggest,
                popupSize: cardSize,
              );
              return Stack(
                children: [
                  Positioned(
                    left: origin.dx,
                    top: origin.dy,
                    width: cardSize.width,
                    height: cardSize.height,
                    child: card,
                  ),
                ],
              );
            },
          ),
        ),
      );
    }

    return Positioned(
      // CompositedTransformFollower handles the X/Y; this Positioned just
      // claims a zero-sized slot so the overlay can render anywhere.
      width: size + 16,
      child: IgnorePointer(
        child: CompositedTransformFollower(
          link: link,
          showWhenUnlinked: false,
          // Anchor: align bottom-centre of popup to top-centre of token, with
          // an 8px gap. If we'd run off the top, fall back to below; handled
          // by the offset clamp inside the inner card via LayoutBuilder.
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -8),
          child: card,
        ),
      ),
    );
  }

  Rect? _anchorRect(BuildContext overlayContext) {
    final anchorContext = placementAnchorKey?.currentContext;
    final anchor = anchorContext?.findRenderObject() as RenderBox?;
    final overlay = overlayContext.findRenderObject() as RenderBox?;
    if (anchor == null || overlay == null || !anchor.hasSize) return null;
    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    return topLeft & anchor.size;
  }
}

Offset clampedHoverPreviewOrigin({
  required Rect anchorRect,
  required Size overlaySize,
  required Size popupSize,
  double margin = 8,
  double preferredVerticalGap = 10,
}) {
  final preferredLeft = anchorRect.center.dx - popupSize.width / 2 - 28;
  final maxLeft = overlaySize.width - popupSize.width - margin;
  final left = preferredLeft.clamp(margin, maxLeft < margin ? margin : maxLeft);

  final belowTop = anchorRect.bottom + preferredVerticalGap;
  final maxTop = overlaySize.height - popupSize.height - margin;
  final fallbackTop = anchorRect.top - popupSize.height - preferredVerticalGap;
  final preferredTop = belowTop <= maxTop ? belowTop : fallbackTop;
  final top = preferredTop.clamp(margin, maxTop < margin ? margin : maxTop);

  return Offset(left.toDouble(), top.toDouble());
}

class _AnimatedHoverCard extends ConsumerStatefulWidget {
  const _AnimatedHoverCard({
    required this.size,
    required this.fen,
    required this.preFen,
    required this.lastMove,
    required this.orientation,
  });

  final double size;
  final String fen;
  final String? preFen;
  final Move? lastMove;
  final Side orientation;

  @override
  ConsumerState<_AnimatedHoverCard> createState() => _AnimatedHoverCardState();
}

class _AnimatedHoverCardState extends ConsumerState<_AnimatedHoverCard> {
  // Spring-driven enter scale + opacity. motor's SingleMotionBuilder
  // animates from 0 → 1 in one go on first frame, matching the rest of
  // the desktop chrome's hover feel.
  double _entered = 0;

  // Two-phase board render: paint the pre-move position first, then on
  // the next frame swap to the post-move FEN so chessground animates the
  // piece slide via its internal `animationDuration`. Highlights only
  // appear once the moving piece lands, so the eye tracks the slide
  // rather than getting anchored to the destination square first.
  late String _boardFen;
  Move? _boardLastMove;
  bool _animating = false;

  @override
  void initState() {
    super.initState();
    _boardFen = widget.preFen ?? widget.fen;
    _boardLastMove = widget.preFen == null ? widget.lastMove : null;
    _animating = widget.preFen != null && widget.lastMove != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _entered = 1;
        _boardFen = widget.fen;
        _boardLastMove = widget.lastMove;
      });
    });
  }

  @override
  void didUpdateWidget(covariant _AnimatedHoverCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen == widget.fen &&
        oldWidget.preFen == widget.preFen &&
        oldWidget.lastMove?.uci == widget.lastMove?.uci) {
      return;
    }
    // Hover target changed (user moved to another token while popup is
    // still mounted). Re-run the two-phase swap so the new move animates
    // rather than appearing already-played.
    _boardFen = widget.preFen ?? widget.fen;
    _boardLastMove = widget.preFen == null ? widget.lastMove : null;
    _animating = widget.preFen != null && widget.lastMove != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _boardFen = widget.fen;
        _boardLastMove = widget.lastMove;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      boardSettingsProviderNew.select(
        (s) => s.valueOrNull ?? const BoardSettingsNew(),
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: SingleMotionBuilder(
        value: _entered,
        motion: DesktopMotion.hover,
        builder: (context, t, child) {
          // Slight upward translation + scale gives the popup a "lift" so
          // the eye registers it as appearing rather than just fading in.
          final scale = 0.94 + 0.06 * t;
          return Opacity(
            opacity: t.clamp(0, 1),
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 6),
              child: Transform.scale(scale: scale, child: child),
            ),
          );
        },
        child: _PopupCard(
          size: widget.size,
          fen: _boardFen,
          lastMove: _boardLastMove,
          animate: _animating,
          orientation: widget.orientation,
          settings: settings,
        ),
      ),
    );
  }
}

class _PopupCard extends StatelessWidget {
  const _PopupCard({
    required this.size,
    required this.fen,
    required this.lastMove,
    required this.animate,
    required this.orientation,
    required this.settings,
  });

  final double size;
  final String fen;
  final Move? lastMove;
  final bool animate;
  final Side orientation;
  final BoardSettingsNew settings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: Chessboard.fixed(
            size: size,
            orientation: orientation,
            fen: fen,
            // Match the main board: paint blue-grey overlays on from/to
            // via squareHighlights and skip chessground's built-in green.
            lastMove: null,
            squareHighlights: _lastMoveHighlights(lastMove),
            settings: ChessboardSettings(
              enableCoordinates: false,
              colorScheme: settings.colorScheme,
              pieceAssets: settings.pieceAssets,
              // Non-zero only when we have a pre-move FEN to slide from —
              // otherwise we'd animate phantom diffs when the popup first
              // mounts on a token we cannot rewind.
              animationDuration:
                  animate ? const Duration(milliseconds: 280) : Duration.zero,
            ),
          ),
        ),
      ),
    );
  }
}

/// Reconstruct the position immediately *before* [move] was played, given
/// the post-move FEN. Used by call sites that don't track move history
/// (e.g. the notation ladder, where each chip only knows its own
/// resulting FEN). Captures lose their captured piece — that square just
/// stays empty in the reversed setup, so chessground will slide the
/// mover in rather than fading the victim out. The animation still reads
/// as a move, which is the point. Returns null when reversal isn't
/// possible (drops, illegal FENs).
String? _reverseToPreMoveFen(String postFen, Move move) {
  if (move is! NormalMove) return null;
  try {
    final setup = Setup.parseFen(postFen);
    final pieceAtTo = setup.board.pieceAt(move.to);
    if (pieceAtTo == null) return null;
    final originalPiece =
        move.promotion != null
            ? Piece(color: pieceAtTo.color, role: Role.pawn)
            : pieceAtTo;
    final newBoard = setup.board
        .removePieceAt(move.to)
        .setPieceAt(move.from, originalPiece);
    final fullmoves =
        (setup.turn == Side.white && setup.fullmoves > 1)
            ? setup.fullmoves - 1
            : setup.fullmoves;
    return Setup(
      board: newBoard,
      turn: setup.turn.opposite,
      castlingRights: setup.castlingRights,
      halfmoves: 0,
      fullmoves: fullmoves,
    ).fen;
  } catch (_) {
    return null;
  }
}

IMap<Square, SquareHighlight> _lastMoveHighlights(Move? lastMove) {
  if (lastMove == null) return const IMapConst<Square, SquareHighlight>({});
  final out = <Square, SquareHighlight>{};
  for (final square in lastMove.squares) {
    final isLight = (square.file + square.rank) % 2 == 1;
    final color =
        isLight ? kLastMoveHighlightLightSquare : kLastMoveHighlightDarkSquare;
    out[square] = SquareHighlight(details: HighlightDetails(solidColor: color));
  }
  return out.lock;
}
