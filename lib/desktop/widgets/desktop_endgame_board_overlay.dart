import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

const String _kStartFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Red wash under the toppled loser king — same value the mobile board uses
/// so the two clients read identically.
const Color _kLoserCellColor = Color(0xCCF53236);

/// Mint wash under both kings on a draw (mobile parity).
const Color _kDrawCellColor = Color(0xCCADE1CD);

/// -45° — the loser king leans over as if knocked down.
const double _kFallenKingAngle = -0.785398;

const cg.SquareHighlight _kLoserHighlight = cg.SquareHighlight(
  details: cg.HighlightDetails(solidColor: _kLoserCellColor),
);

/// A static [cg.StaticChessboard] preview that decorates *finished* games the
/// way the mobile small board does: the losing king topples 45° onto a red
/// square, and draws park a dove on each king over a mint square.
///
/// For ongoing/unknown games this is just the plain board, so callers can use
/// it as a drop-in replacement for `StaticChessboard` inside grid cards.
///
/// Mechanic: the losing king stays in the FEN and is leaned over by the board's
/// own cached piece painter (`pieceRotations`), with the red wash painted as an
/// under-piece square highlight. It is never stripped from the position and
/// redrawn by a separate image widget: when that replacement failed to paint
/// (reported on Firefox in the browser build) the square was left empty.
/// Preview endings are visible immediately. Scrolling a finished game into
/// view must not restart a decorative spring or a delayed badge animation;
/// interactive boards keep their move and result animations separately.
class DesktopEndgameBoard extends StatelessWidget {
  const DesktopEndgameBoard({
    super.key,
    required this.size,
    required this.fen,
    required this.orientation,
    required this.status,
    required this.settings,
    this.lastMove,
  });

  final double size;
  final String fen;
  final Side orientation;
  final GameStatus status;
  final BoardSettingsNew settings;
  final Move? lastMove;

  @override
  Widget build(BuildContext context) {
    final isWhiteWins = status == GameStatus.whiteWins;
    final isBlackWins = status == GameStatus.blackWins;
    final isDraw = status == GameStatus.draw;
    final isDecisive = isWhiteWins || isBlackWins;

    final rawFen = fen.trim();
    final setup = _tryParseFen(rawFen);
    final displayFen = setup != null ? rawFen : _kStartFen;

    Square? whiteKingSquare;
    Square? blackKingSquare;
    if ((isDecisive || isDraw) && setup != null) {
      // Locate kings straight off the parsed board — cheaper than a full
      // legality pass and we only need their squares.
      for (final (square, piece) in setup.board.pieces) {
        if (piece.role == Role.king) {
          if (piece.color == Side.white) {
            whiteKingSquare = square;
          } else {
            blackKingSquare = square;
          }
        }
      }
    }

    Square? loserKingSquare;
    if (isWhiteWins) {
      loserKingSquare = blackKingSquare;
    } else if (isBlackWins) {
      loserKingSquare = whiteKingSquare;
    }

    final board = cg.StaticChessboard(
      size: size,
      fen: displayFen,
      orientation: orientation,
      settings: cg.StaticChessboardSettings.fromBoardSettings(
        cg.ChessboardSettings(
          enableCoordinates: false,
          colorScheme: settings.colorScheme,
          pieceAssets: settings.pieceAssets,
        ),
      ),
      shapes: const <cg.Shape>{},
      lastMove: lastMove,
      // Decisive: red square under the loser, king toppled in place.
      squareHighlights:
          loserKingSquare == null
              ? const <Square, cg.SquareHighlight>{}
              : {loserKingSquare: _kLoserHighlight},
      pieceRotations:
          loserKingSquare == null
              ? const <Square, double>{}
              : {loserKingSquare: _kFallenKingAngle},
    );

    // Draw: mint square + dove on each king.
    if (isDraw && whiteKingSquare != null && blackKingSquare != null) {
      final squareSize = size / 8;
      final wOff = _orientedSquareOffset(
        whiteKingSquare,
        squareSize,
        orientation,
      );
      final bOff = _orientedSquareOffset(
        blackKingSquare,
        squareSize,
        orientation,
      );

      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            board,
            _CellWash(
              left: wOff.left,
              top: wOff.top,
              squareSize: squareSize,
              color: _kDrawCellColor,
            ),
            _CellWash(
              left: bOff.left,
              top: bOff.top,
              squareSize: squareSize,
              color: _kDrawCellColor,
            ),
            _PeaceIcon(
              square: whiteKingSquare,
              squareSize: squareSize,
              orientation: orientation,
            ),
            _PeaceIcon(
              square: blackKingSquare,
              squareSize: squareSize,
              orientation: orientation,
            ),
          ],
        ),
      );
    }

    return board;
  }
}

/// Flat colour wash over a single square (draw mint).
class _CellWash extends StatelessWidget {
  const _CellWash({
    required this.left,
    required this.top,
    required this.squareSize,
    required this.color,
  });

  final double left;
  final double top;
  final double squareSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(width: squareSize, height: squareSize, color: color),
      ),
    );
  }
}

/// A settled result badge, visible from the preview's first frame.
class _PeaceIcon extends StatelessWidget {
  const _PeaceIcon({
    required this.square,
    required this.squareSize,
    required this.orientation,
  });

  final Square square;
  final double squareSize;
  final Side orientation;

  @override
  Widget build(BuildContext context) {
    final off = _orientedSquareOffset(square, squareSize, orientation);
    final containerSize = squareSize * 0.28;
    return Positioned(
      left: off.left + squareSize - containerSize - 1,
      top: off.top + 1,
      child: IgnorePointer(
        child: Container(
          width: containerSize,
          height: containerSize,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Center(
            child: ColorFiltered(
              colorFilter: const ColorFilter.mode(
                Colors.black,
                BlendMode.srcIn,
              ),
              child: Text(
                '🕊️',
                style: TextStyle(fontSize: containerSize * 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Setup? _tryParseFen(String fen) {
  if (fen.trim().isEmpty) return null;
  try {
    return Setup.parseFen(fen);
  } catch (_) {
    return null;
  }
}

/// Top-left pixel offset of [square] for a board of [squareSize] cells,
/// accounting for board [orientation].
({double left, double top}) _orientedSquareOffset(
  Square square,
  double squareSize,
  Side orientation,
) {
  final file = square.file;
  final rank = square.rank;
  if (orientation == Side.black) {
    return (left: (7 - file) * squareSize, top: rank * squareSize);
  }
  return (left: file * squareSize, top: (7 - rank) * squareSize);
}
