import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop-tuned wrapper around chessground's [Chessboard].
///
/// Differs from the mobile [`chess_board_screen_new.dart`] usage in three
/// ways:
/// 1. `pieceShiftMethod: either` — pieces respond to both click-to-select-
///    then-click-target *and* mouse drag-and-drop. Mobile uses
///    `tapTwoSquares` because finger drags are too imprecise on phones.
/// 2. `dragTargetKind: square` — a square ring shows under the cursor
///    while dragging, the way desktop database boards highlight destinations.
/// 3. OS `grab` / `grabbing` cursors and a single-square spring cue show
///    that the hovered piece is playable without rebuilding every piece.
class DesktopChessBoard extends ConsumerStatefulWidget {
  const DesktopChessBoard({
    super.key,
    required this.size,
    required this.fen,
    required this.orientation,
    required this.playerSide,
    required this.sideToMove,
    required this.validMoves,
    required this.onMove,
    this.lastMove,
    this.premove,
    this.onSetPremove,
    this.promotionMove,
    this.onPromotionSelection,
    this.shapes = const ISet<Shape>.empty(),
    this.squareHighlights = const IMapConst<Square, SquareHighlight>({}),
    this.isCheck = false,
  });

  final double size;
  final String fen;
  final Side orientation;
  final PlayerSide playerSide;
  final Side sideToMove;
  final ValidMoves validMoves;
  final void Function(Move move, {bool? viaDragAndDrop}) onMove;
  final Move? lastMove;
  final Move? premove;
  final void Function(Move? move)? onSetPremove;
  final NormalMove? promotionMove;
  final void Function(Role? role)? onPromotionSelection;
  final ISet<Shape> shapes;

  /// Solid-colour overlays painted under the pieces — used for the red
  /// loser-king highlight and the mint-green draw highlight when a game
  /// ends. Empty by default so freeplay rendering is unchanged.
  final IMap<Square, SquareHighlight> squareHighlights;
  final bool isCheck;

  @override
  ConsumerState<DesktopChessBoard> createState() => _DesktopChessBoardState();
}

class _DesktopChessBoardState extends ConsumerState<DesktopChessBoard> {
  int _gestureResetEpoch = 0;

  void _cancelActivePieceGesture() {
    if (!mounted) return;
    setState(() {
      _gestureResetEpoch += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Build per-square highlights for the from / to of `lastMove` using
    // the same blue-grey palette mobile uses (kLastMoveHighlightLight /
    // DarkSquare). We deliberately do NOT pass `lastMove:` to the inner
    // Chessboard — that would tell chessground to paint its built-in
    // greenish highlight, which doesn't match the brand. Squarehighlights
    // are the canonical mobile path; we mirror it.
    final mergedHighlights = _mergedHighlights(
      widget.squareHighlights,
      widget.lastMove,
    );
    // Pull the user-selected board theme + piece set from the same store
    // the Board Settings page writes to. One change in Settings re-skins
    // every desktop board on screen.
    final settings =
        ref.watch(boardSettingsProviderNew).valueOrNull ??
        const BoardSettingsNew();
    return DesktopBoardHoverAffordance(
      size: widget.size,
      pieces: readFen(widget.fen),
      orientation: widget.orientation,
      canGrabPiece: _canGrabPiece,
      onCancelActivePieceGesture: _cancelActivePieceGesture,
      child: Chessboard(
        key: ValueKey<int>(_gestureResetEpoch),
        size: widget.size,
        settings: ChessboardSettings(
          enableCoordinates: true,
          animationDuration: const Duration(milliseconds: 180),
          dragFeedbackScale: 1.05,
          dragTargetKind: DragTargetKind.square,
          // Desktop has both fine pointer (mouse) and clicks; allow both.
          pieceShiftMethod: PieceShiftMethod.either,
          // Premoves are speculative; queueing a pawn premove to the last
          // rank without a role would drain to an illegal move and flush the
          // whole queue. Default to queen (chess.com behavior); user can
          // tweak after the move plays.
          autoQueenPromotionOnPremove: true,
          pieceOrientationBehavior: PieceOrientationBehavior.facingUser,
          colorScheme: settings.colorScheme,
          pieceAssets: settings.pieceAssets,
        ),
        orientation: widget.orientation,
        fen: widget.fen,
        // Pass `null` so chessground skips its own greenish highlight.
        // Our blue-grey overlays in `mergedHighlights` are the canonical
        // last-move indicator.
        lastMove: null,
        shapes: widget.shapes,
        squareHighlights: mergedHighlights,
        game: GameData(
          playerSide: widget.playerSide,
          validMoves: widget.validMoves,
          sideToMove: widget.sideToMove,
          isCheck: widget.isCheck,
          promotionMove: widget.promotionMove,
          premovable: widget.onSetPremove == null
              ? null
              : (premove: widget.premove, onSetPremove: widget.onSetPremove!),
          onMove: widget.onMove,
          onPromotionSelection: (role) =>
              widget.onPromotionSelection?.call(role),
        ),
      ),
    );
  }

  bool _canGrabPiece(Piece piece) {
    final controlsPiece = switch (widget.playerSide) {
      PlayerSide.none => false,
      PlayerSide.both => true,
      PlayerSide.white => piece.color == Side.white,
      PlayerSide.black => piece.color == Side.black,
    };
    if (!controlsPiece) return false;
    return piece.color == widget.sideToMove || widget.onSetPremove != null;
  }
}

/// Adds the desktop board hover affordance used by all interactive board
/// surfaces: grab/grabbing cursor and the animated square cue.
class DesktopBoardHoverAffordance extends StatefulWidget {
  const DesktopBoardHoverAffordance({
    super.key,
    required this.size,
    required this.pieces,
    required this.orientation,
    required this.child,
    this.canGrabPiece,
    this.onCancelActivePieceGesture,
    this.enabled = true,
  });

  final double size;
  final Pieces pieces;
  final Side orientation;
  final Widget child;
  final bool Function(Piece piece)? canGrabPiece;
  final VoidCallback? onCancelActivePieceGesture;
  final bool enabled;

  @override
  State<DesktopBoardHoverAffordance> createState() =>
      _DesktopBoardHoverAffordanceState();
}

class _DesktopBoardHoverAffordanceState
    extends State<DesktopBoardHoverAffordance> {
  Square? _hoveredSquare;
  Square? _pressedSquare;
  bool _primaryDownOnPiece = false;

  @override
  void didUpdateWidget(DesktopBoardHoverAffordance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled && !widget.enabled) {
      _pressedSquare = null;
      _primaryDownOnPiece = false;
    }
    if (_pressedSquare != null && !_canGrab(_pieceAt(_pressedSquare))) {
      _pressedSquare = null;
      _primaryDownOnPiece = false;
    }
    if (oldWidget.pieces != widget.pieces ||
        oldWidget.enabled != widget.enabled) {
      if (_hoveredSquare != null && !_canGrab(_pieceAt(_hoveredSquare))) {
        _hoveredSquare = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final hoverPiece = _pieceAt(_hoveredSquare);
    final canGrab = _canGrab(hoverPiece);
    final cueSquare = _primaryDownOnPiece
        ? _pressedSquare
        : (canGrab ? _hoveredSquare : null);
    final cursor = _primaryDownOnPiece
        ? SystemMouseCursors.grabbing
        : canGrab
        ? SystemMouseCursors.grab
        : MouseCursor.defer;

    return SizedBox.square(
      dimension: widget.size,
      child: MouseRegion(
        cursor: cursor,
        onEnter: (event) => _updateHoveredSquare(event.localPosition),
        onHover: (event) => _updateHoveredSquare(event.localPosition),
        onExit: (_) {
          if (_hoveredSquare != null || _pressedSquare != null) {
            setState(() {
              _hoveredSquare = null;
              if (!_primaryDownOnPiece) {
                _pressedSquare = null;
              }
            });
          }
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            if (_hasSecondaryButton(event.buttons)) {
              _cancelActivePieceGesture();
              return;
            }
            if (event.buttons != kPrimaryButton) return;
            final downSquare = _squareAt(event.localPosition);
            final downPiece = _pieceAt(downSquare);
            if (!_canGrab(downPiece)) return;
            setState(() {
              _hoveredSquare = downSquare;
              _pressedSquare = downSquare;
              _primaryDownOnPiece = true;
            });
          },
          onPointerMove: (event) {
            if (_hasSecondaryButton(event.buttons)) {
              _cancelActivePieceGesture();
            }
          },
          onPointerUp: (_) => _clearPrimaryDown(),
          onPointerCancel: (_) => _clearPrimaryDown(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (cueSquare != null)
                _HoverSquareCue(
                  key: ValueKey(cueSquare),
                  square: cueSquare,
                  size: widget.size,
                  orientation: widget.orientation,
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _canGrab(Piece? piece) {
    if (piece == null) return false;
    return widget.canGrabPiece?.call(piece) ?? true;
  }

  bool _hasSecondaryButton(int buttons) => buttons & kSecondaryButton != 0;

  void _cancelActivePieceGesture() {
    if (!_primaryDownOnPiece) return;
    widget.onCancelActivePieceGesture?.call();
    setState(() {
      _pressedSquare = null;
      _primaryDownOnPiece = false;
    });
  }

  void _clearPrimaryDown() {
    if (!_primaryDownOnPiece) return;
    setState(() {
      _pressedSquare = null;
      _primaryDownOnPiece = false;
    });
  }

  void _updateHoveredSquare(Offset localPosition) {
    final nextSquare = _squareAt(localPosition);
    if (nextSquare == _hoveredSquare) return;
    setState(() {
      _hoveredSquare = nextSquare;
      if (!_primaryDownOnPiece) {
        _pressedSquare = null;
      }
    });
  }

  Piece? _pieceAt(Square? square) =>
      square == null ? null : widget.pieces[square];

  Square? _squareAt(Offset localPosition) {
    if (localPosition.dx < 0 || localPosition.dy < 0) return null;
    if (localPosition.dx >= widget.size || localPosition.dy >= widget.size) {
      return null;
    }
    final squareSize = widget.size / 8;
    final x = (localPosition.dx / squareSize).floor();
    final y = (localPosition.dy / squareSize).floor();
    final file = widget.orientation == Side.black ? 7 - x : x;
    final rank = widget.orientation == Side.black ? y : 7 - y;
    if (file < 0 || file > 7 || rank < 0 || rank > 7) return null;
    return Square.fromCoords(File(file), Rank(rank));
  }
}

class _HoverSquareCue extends StatelessWidget {
  const _HoverSquareCue({
    super.key,
    required this.square,
    required this.size,
    required this.orientation,
  });

  final Square square;
  final double size;
  final Side orientation;

  @override
  Widget build(BuildContext context) {
    final squareSize = size / 8;
    final left =
        (orientation == Side.black ? 7 - square.file : square.file) *
        squareSize;
    final top =
        (orientation == Side.black ? square.rank : 7 - square.rank) *
        squareSize;

    return Positioned(
      left: left,
      top: top,
      width: squareSize,
      height: squareSize,
      child: IgnorePointer(
        child: SingleMotionBuilder(
          motion: DesktopMotion.hover,
          from: 0,
          value: 1,
          builder: (context, value, child) {
            final t = value.clamp(0.0, 1.0);
            return Transform.scale(
              scale: 0.88 + (0.12 * t),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: kPrimaryColor.withValues(alpha: 0.08 * t),
                  border: Border.all(
                    color: kPrimaryColor.withValues(alpha: 0.42 * t),
                    width: 1.25,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Whether a square is light-coloured (a1 dark, parity-based — same
/// formula mobile uses).
bool _isLightSquare(Square square) => (square.file + square.rank) % 2 == 1;

/// Merge caller-supplied highlights (loser-king red / draw-king mint)
/// with last-move blue-grey overlays. Caller-supplied wins on conflict
/// so the end-game red on the loser's king is preserved even when the
/// king's destination square is also the last-move square.
IMap<Square, SquareHighlight> _mergedHighlights(
  IMap<Square, SquareHighlight> caller,
  Move? lastMove,
) {
  if (lastMove == null) return caller;
  final out = <Square, SquareHighlight>{};
  for (final square in lastMove.squares) {
    final color = _isLightSquare(square)
        ? kLastMoveHighlightLightSquare
        : kLastMoveHighlightDarkSquare;
    out[square] = SquareHighlight(details: HighlightDetails(solidColor: color));
  }
  // Caller's overlays (end-game etc.) take precedence.
  for (final entry in caller.entries) {
    out[entry.key] = entry.value;
  }
  return out.lock;
}
