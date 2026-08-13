import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/widgets/spring_tokens.dart';
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

/// A static [cg.StaticChessboard] preview that decorates *finished* games the
/// way the mobile small board does: the losing king topples 45° onto a red
/// square, and draws park a dove on each king over a mint square.
///
/// For ongoing/unknown games this is just the plain board, so callers can use
/// it as a drop-in replacement for `StaticChessboard` inside grid cards.
///
/// Mechanic (mirrors mobile `chess_board_from_fen_new.dart`): chessground draws
/// pieces internally with no per-piece rotation hook, so the loser king is
/// *stripped from the FEN* and re-drawn as a rotated overlay sprite on top.
/// Motion uses [DesktopMotion.arrival] — the shell's "king tilt" token — rather
/// than mobile's raw `elasticOut`, keeping the curve consistent with the rest
/// of the desktop chrome while the angle and colours stay pixel-true to mobile.
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
    var displayFen = setup != null ? rawFen : _kStartFen;

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
    if (isWhiteWins && blackKingSquare != null) {
      loserKingSquare = blackKingSquare;
      displayFen = _removeKingFromFen(displayFen, loserKingSquare, 'k');
    } else if (isBlackWins && whiteKingSquare != null) {
      loserKingSquare = whiteKingSquare;
      displayFen = _removeKingFromFen(displayFen, loserKingSquare, 'K');
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
    );

    // Decisive: red square under the loser, king toppled on top.
    if (loserKingSquare != null) {
      final squareSize = size / 8;
      final loserSide = isWhiteWins ? Side.black : Side.white;
      final pieceKind =
          loserSide == Side.white ? PieceKind.whiteKing : PieceKind.blackKing;
      final pieceImage = settings.pieceAssets[pieceKind];
      final off = _orientedSquareOffset(
        loserKingSquare,
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
              left: off.left,
              top: off.top,
              squareSize: squareSize,
              color: _kLoserCellColor,
            ),
            if (pieceImage != null)
              _FallenKing(
                left: off.left,
                top: off.top,
                squareSize: squareSize,
                image: pieceImage,
              ),
          ],
        ),
      );
    }

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
              delayMs: 0,
            ),
            _PeaceIcon(
              square: blackKingSquare,
              squareSize: squareSize,
              orientation: orientation,
              delayMs: 100,
            ),
          ],
        ),
      );
    }

    return board;
  }
}

/// Flat colour wash over a single square (loser red / draw mint).
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

/// The loser's king, re-drawn over its (now empty) square and leaned to
/// [_kFallenKingAngle] with the bouncy [DesktopMotion.arrival] spring on mount.
class _FallenKing extends StatelessWidget {
  const _FallenKing({
    required this.left,
    required this.top,
    required this.squareSize,
    required this.image,
  });

  final double left;
  final double top;
  final double squareSize;
  final ImageProvider image;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      width: squareSize,
      height: squareSize,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: SingleMotionBuilder(
            motion: DesktopMotion.arrival,
            from: 0,
            value: _kFallenKingAngle,
            builder: (context, value, child) {
              return Transform.rotate(
                angle: value,
                alignment: Alignment.center,
                child: child,
              );
            },
            child: Center(
              child: Image(
                image: ResizeImage.resizeIfNeeded(
                  (squareSize * MediaQuery.devicePixelRatioOf(context)).round(),
                  (squareSize * MediaQuery.devicePixelRatioOf(context)).round(),
                  image,
                ),
                width: squareSize,
                height: squareSize,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dove perched on a king's square for draws. Pops in (scale 0→1) on mount,
/// optionally after [delayMs] so the two doves land in sequence.
class _PeaceIcon extends StatefulWidget {
  const _PeaceIcon({
    required this.square,
    required this.squareSize,
    required this.orientation,
    required this.delayMs,
  });

  final Square square;
  final double squareSize;
  final Side orientation;
  final int delayMs;

  @override
  State<_PeaceIcon> createState() => _PeaceIconState();
}

class _PeaceIconState extends State<_PeaceIcon> {
  double _target = 0;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) setState(() => _target = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final off = _orientedSquareOffset(
      widget.square,
      widget.squareSize,
      widget.orientation,
    );
    final containerSize = widget.squareSize * 0.28;

    return Positioned(
      left: off.left + widget.squareSize - containerSize - 1,
      top: off.top + 1,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: SingleMotionBuilder(
            motion: DesktopMotion.arrival,
            from: 0,
            value: _target,
            builder: (context, value, child) {
              return Transform.scale(
                scale: value.clamp(0.0, 1.0),
                alignment: Alignment.topRight,
                child: child,
              );
            },
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

/// Blank a single king out of the FEN's piece placement so the upright sprite
/// stops rendering and the rotated overlay can stand in for it.
String _removeKingFromFen(String fen, Square square, String kingChar) {
  final parts = fen.split(' ');
  if (parts.isEmpty) return fen;

  final ranks = parts[0].split('/');
  final rankIndex = 7 - square.rank;
  if (rankIndex < 0 || rankIndex >= ranks.length) return fen;

  final expanded = StringBuffer();
  for (final char in ranks[rankIndex].split('')) {
    final digit = int.tryParse(char);
    if (digit != null) {
      expanded.write('1' * digit);
    } else {
      expanded.write(char);
    }
  }

  final fileIndex = square.file;
  final chars = expanded.toString().split('');
  if (fileIndex >= 0 &&
      fileIndex < chars.length &&
      chars[fileIndex] == kingChar) {
    chars[fileIndex] = '1';
  }

  final compressed = StringBuffer();
  var emptyCount = 0;
  for (final char in chars) {
    if (char == '1') {
      emptyCount++;
    } else {
      if (emptyCount > 0) {
        compressed.write(emptyCount);
        emptyCount = 0;
      }
      compressed.write(char);
    }
  }
  if (emptyCount > 0) compressed.write(emptyCount);

  ranks[rankIndex] = compressed.toString();
  parts[0] = ranks.join('/');
  return parts.join(' ');
}
