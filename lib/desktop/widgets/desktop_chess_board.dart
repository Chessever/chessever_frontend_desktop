import 'dart:math' as math;

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

  // chessground 10 drives the interactive board through a controller instead
  // of rebuilding the widget with a new `fen` each frame. We own it: created
  // in initState from the current props, advanced in didUpdateWidget, disposed
  // below. A game switch / reseed remounts this whole widget (board_pane hands
  // us a fresh key), so those get a brand-new controller — an instant cut, not
  // an animated diff. Same-key fen changes (a played move, one-step nav) flow
  // through updatePosition() and animate the single-move slide.
  late ChessboardController _controller;

  // Memoize the FEN→pieces parse. build() runs on every parent repaint
  // (per-second clock tick, eval updates, hover affordance) but the parsed
  // position only changes when the FEN string itself does. readFen() walks
  // the board and allocates a fresh Pieces map each call, so caching keeps
  // those between-move frames allocation-free.
  String? _piecesFen;
  late Pieces _pieces;

  Pieces _piecesForFen(String fen) {
    if (_piecesFen != fen) {
      _piecesFen = fen;
      _pieces = readFen(fen);
    }
    return _pieces;
  }

  @override
  void initState() {
    super.initState();
    _controller = ChessboardController(game: _gameData());
    if (widget.premove != null) {
      _controller.premove = widget.premove;
    }
    // v10 owns the premove on the controller. The play board keeps its own
    // premove queue, so bridge user-initiated premove changes back out.
    _controller.premoveNotifier.addListener(_handleControllerPremove);
  }

  void _handleControllerPremove() {
    final next = _controller.premove;
    // Only forward changes the user made on the board — not the ones we just
    // pushed in from widget.premove — so the queue↔controller sync can't loop.
    if (next != widget.premove) {
      widget.onSetPremove?.call(next);
    }
  }

  @override
  void didUpdateWidget(DesktopChessBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.premove != oldWidget.premove &&
        widget.premove != _controller.premove) {
      _controller.premove = widget.premove;
    }
    // Only push the controller when the position or game state actually
    // changes. Same-fen repaints (clock ticks, hover affordance, eval updates)
    // are skipped so the board layer stays still. updatePosition() animates
    // when the fen differs and no-ops the animation when it doesn't.
    if (oldWidget.fen != widget.fen ||
        oldWidget.lastMove != widget.lastMove ||
        oldWidget.playerSide != widget.playerSide ||
        oldWidget.sideToMove != widget.sideToMove ||
        oldWidget.isCheck != widget.isCheck) {
      _controller.updatePosition(_gameData());
    }
  }

  @override
  void dispose() {
    _controller.premoveNotifier.removeListener(_handleControllerPremove);
    _controller.dispose();
    super.dispose();
  }

  GameData _gameData() => GameData(
    fen: widget.fen,
    playerSide: widget.playerSide,
    sideToMove: widget.sideToMove,
    validMoves: widget.validMoves,
    lastMove: widget.lastMove,
    kingSquareInCheck: _kingSquareInCheck(),
  );

  // v10 wants the king's square (not a bool) to paint the in-check ring. Read
  // it off the already-parsed pieces map so we don't re-walk the FEN.
  Square? _kingSquareInCheck() {
    if (!widget.isCheck) return null;
    for (final entry in _piecesForFen(widget.fen).entries) {
      if (entry.value.role == Role.king && entry.value.color == widget.sideToMove) {
        return entry.key;
      }
    }
    return null;
  }

  void _cancelActivePieceGesture() {
    if (!mounted) return;
    setState(() {
      _gestureResetEpoch += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Pull the user-selected board theme + piece set from the same store
    // the Board Settings page writes to. One change in Settings re-skins
    // every desktop board on screen.
    final settings =
        ref.watch(boardSettingsProviderNew).valueOrNull ??
        const BoardSettingsNew();
    return RepaintBoundary(
      // Isolate the board layer: a parent repaint (1 Hz clock tick, eval bar
      // fill animation, sibling hover) must not re-rasterize the chessground
      // scene. Only a real fen/shape/highlight change repaints the board.
      child: DesktopBoardHoverAffordance(
        size: widget.size,
        pieces: _piecesForFen(widget.fen),
        orientation: widget.orientation,
        canGrabPiece: _canGrabPiece,
        onCancelActivePieceGesture: _cancelActivePieceGesture,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Chessboard(
              key: ValueKey<int>(_gestureResetEpoch),
              size: widget.size,
              controller: _controller,
              settings: ChessboardSettings(
                enableCoordinates: true,
                animationDuration: const Duration(milliseconds: 180),
                dragFeedbackScale: 1.05,
                dragTargetKind: DragTargetKind.square,
                // Desktop has both fine pointer (mouse) and clicks; allow both.
                pieceShiftMethod: PieceShiftMethod.either,
                // Premoves are speculative; queueing a pawn premove to the last
                // rank without a role would drain to an illegal move and flush
                // the whole queue. Default to queen (chess.com behavior).
                autoQueenPromotionOnPremove: true,
                // Premoves only make sense on the live play board, which opts
                // in by wiring onSetPremove. The analysis board leaves it off.
                enablePremoves: widget.onSetPremove != null,
                pieceOrientationBehavior: PieceOrientationBehavior.facingUser,
                // v10 paints the last-move highlight from GameData.lastMove via
                // the color scheme (under the pieces). Recolour it to the brand
                // blue-grey so we keep the desktop look that 9.x faked with
                // squareHighlights — no separate overlay needed.
                colorScheme: _brandLastMove(settings.colorScheme),
                pieceAssets: settings.pieceAssets,
              ),
              orientation: widget.orientation,
              // Promotion is handled inside the board in v10: it raises its own
              // selector and calls onMove once with the promotion role already
              // set, so we no longer stage promotionMove/onPromotionSelection.
              onMove: widget.onMove,
              shapes: widget.shapes.unlockView,
            ),
            // The interactive board dropped squareHighlights in v10. Caller
            // highlights (end-game king markers, the play board's premove
            // heat map) are painted as a soft overlay above the pieces.
            if (widget.squareHighlights.isNotEmpty)
              _SquareHighlightOverlay(
                size: widget.size,
                orientation: widget.orientation,
                highlights: widget.squareHighlights,
              ),
          ],
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
    final cueSquare =
        _primaryDownOnPiece
            ? _pressedSquare
            : (canGrab ? _hoveredSquare : null);
    final cursor =
        _primaryDownOnPiece
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
              filterQuality: FilterQuality.medium,
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

/// Rebuild [base] with the brand blue-grey last-move highlight. v10 paints the
/// last move from the color scheme (under the pieces), and [ChessboardColorScheme]
/// has no copyWith, so thread every field through and override only `lastMove`.
/// This keeps the desktop look that 9.x faked with squareHighlights.
ChessboardColorScheme _brandLastMove(ChessboardColorScheme base) {
  return ChessboardColorScheme(
    lightSquare: base.lightSquare,
    darkSquare: base.darkSquare,
    background: base.background,
    whiteCoordBackground: base.whiteCoordBackground,
    blackCoordBackground: base.blackCoordBackground,
    lastMove: const HighlightDetails(solidColor: kLastMoveHighlightLightSquare),
    selected: base.selected,
    validMoves: base.validMoves,
    validPremoves: base.validPremoves,
  );
}

/// Soft translucent fills for caller-supplied square highlights — end-game
/// king markers (loser red / draw mint) and the play board's premove heat map.
/// The interactive board no longer paints squareHighlights itself, so we
/// overlay them above the pieces. Each fill keeps its own alpha (so the heat
/// map's gradient survives) but is capped so a piece sitting on the square is
/// never fully hidden; the opaque loser-king is redrawn on top by board_pane's
/// _FallenKingOverlay anyway.
class _SquareHighlightOverlay extends StatelessWidget {
  const _SquareHighlightOverlay({
    required this.size,
    required this.orientation,
    required this.highlights,
  });

  final double size;
  final Side orientation;
  final IMap<Square, SquareHighlight> highlights;

  @override
  Widget build(BuildContext context) {
    final squareSize = size / 8;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final entry in highlights.entries)
            if (entry.value.details.solidColor != null)
              Positioned(
                left:
                    (orientation == Side.black
                        ? 7 - entry.key.file
                        : entry.key.file) *
                    squareSize,
                top:
                    (orientation == Side.black
                        ? entry.key.rank
                        : 7 - entry.key.rank) *
                    squareSize,
                width: squareSize,
                height: squareSize,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: entry.value.details.solidColor!.withValues(
                      alpha: math.min(
                        entry.value.details.solidColor!.a,
                        0.6,
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
