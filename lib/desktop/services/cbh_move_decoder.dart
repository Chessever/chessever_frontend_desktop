import 'package:dartchess/dartchess.dart';

import 'cbh_frame_reader.dart';
import 'cbh_index_reader.dart';
import 'cbh_move_tables.dart';

/// Decodes ordinary classic-CBH move streams with an independent Dart board.
/// Unsupported positions and opcodes fail the entire record.
final class CbhMoveDecoder {
  CbhMoveDecoder();

  Position _position = Chess.initial;
  final _pieces = <(Side, Role), List<int?>>{};
  final _san = <String>[];

  List<String> decode(CbhGameFrame frame) {
    if (frame.chess960 || frame.startingPosition != null) {
      throw const CbhFormatException(
        'Custom starting positions and Chess960 are not decoded yet.',
      );
    }
    _position = Chess.initial;
    _san.clear();
    _resetPieces();
    var moveNumber = 0;
    final bytes = frame.moveBytes;
    for (var cursor = 0; cursor < bytes.length; cursor++) {
      final code = cbhMoveLookup[(bytes[cursor] - moveNumber) & 255];
      if (code >= 0xec && code <= 0xfd) {
        throw CbhFormatException('Unsupported CBH move opcode $code.');
      }
      if (code == 0xfe || code == 0xff) {
        throw const CbhFormatException('CBH variations are not decoded yet.');
      }
      if (code == 0) {
        throw const CbhFormatException('CBH null moves are not decoded yet.');
      }
      if (code == 0xeb) {
        if (bytes.length - cursor < 3) {
          throw const CbhFormatException('Truncated CBH multibyte move.');
        }
        final high = cbhMoveLookup[(bytes[++cursor] - moveNumber) & 255];
        final low = cbhMoveLookup[(bytes[++cursor] - moveNumber) & 255];
        final word = (high << 8) | low;
        final from = _mapSquare(word & 63);
        final to = _mapSquare((word >> 6) & 63);
        if (from == to) {
          throw const CbhFormatException(
            'Chess960 castling is not decoded yet.',
          );
        }
        final piece = _position.board.pieceAt(Square(from));
        if (piece == null || piece.color != _position.turn) {
          throw const CbhFormatException('Invalid CBH multibyte move source.');
        }
        final promoted =
            piece.role == Role.pawn && (to ~/ 8 == 0 || to ~/ 8 == 7)
                ? const [
                  Role.queen,
                  Role.rook,
                  Role.bishop,
                  Role.knight,
                ][(word >> 12) & 3]
                : null;
        _play(from, to, promotion: promoted);
      } else if (code == 9 || code == 10) {
        final white = _position.turn == Side.white;
        _play(
          white ? 4 : 60,
          white ? (code == 9 ? 6 : 2) : (code == 9 ? 62 : 58),
        );
      } else {
        final instruction = _instruction(code);
        if (instruction == null) {
          throw CbhFormatException('Unsupported CBH move opcode $code.');
        }
        final (role, pieceNumber, offset, wrap) = instruction;
        final pieces = _pieces[(_position.turn, role)]!;
        if (pieceNumber >= pieces.length || pieces[pieceNumber] == null) {
          throw const CbhFormatException('Invalid CBH piece reference.');
        }
        final from = pieces[pieceNumber]!;
        var delta = offset;
        if (role == Role.pawn && _position.turn == Side.black) delta = -delta;
        if (wrap && (from & 7) + (delta & 7) > 7) delta -= 8;
        final to = (from + delta) & 63;
        _play(from, to);
      }
      moveNumber++;
    }
    return List.unmodifiable(_san);
  }

  void _resetPieces() {
    _pieces.clear();
    for (final side in Side.values) {
      final rank = side == Side.white ? 0 : 7;
      final pawnRank = side == Side.white ? 1 : 6;
      _pieces[(side, Role.king)] = [rank * 8 + 4];
      _pieces[(side, Role.queen)] = [rank * 8 + 3];
      _pieces[(side, Role.rook)] = [rank * 8, rank * 8 + 7];
      _pieces[(side, Role.bishop)] = [rank * 8 + 2, rank * 8 + 5];
      _pieces[(side, Role.knight)] = [rank * 8 + 1, rank * 8 + 6];
      _pieces[(side, Role.pawn)] = [
        for (var file = 0; file < 8; file++) pawnRank * 8 + file,
      ];
    }
  }

  void _play(int from, int to, {Role? promotion}) {
    final before = _position;
    final mover = before.board.pieceAt(Square(from));
    if (mover == null || mover.color != before.turn) {
      throw const CbhFormatException('CBH move has no matching piece.');
    }
    final side = before.turn;
    final capturedSquare =
        mover.role == Role.pawn &&
                (from & 7) != (to & 7) &&
                before.board.pieceAt(Square(to)) == null
            ? to + (side == Side.white ? -8 : 8)
            : to;
    final captured = before.board.pieceAt(Square(capturedSquare));
    final moving = _pieces[(side, mover.role)]!;
    final movingSlot = moving.indexOf(from);
    if (movingSlot < 0) {
      throw const CbhFormatException('CBH piece identity is inconsistent.');
    }
    Position after;
    String san;
    try {
      (after, san) = before.makeSan(
        NormalMove(from: Square(from), to: Square(to), promotion: promotion),
      );
    } on PlayException {
      throw const CbhFormatException('CBH record contains an illegal move.');
    }
    if (captured != null && captured.color != side) {
      final capturedList = _pieces[(captured.color, captured.role)]!;
      final slot = capturedList.indexOf(capturedSquare);
      if (slot < 0) {
        throw const CbhFormatException(
          'CBH captured piece identity is inconsistent.',
        );
      }
      capturedList[slot] = null;
      if (captured.role != Role.pawn && slot < 2) {
        for (var i = slot; i + 1 < capturedList.length && i < 2; i++) {
          capturedList[i] = capturedList[i + 1];
          capturedList[i + 1] = null;
        }
      }
    }
    if (promotion == null) {
      moving[movingSlot] = to;
    } else {
      moving[movingSlot] = null;
      final promotedList = _pieces[(side, promotion)]!;
      final free = promotedList.indexOf(null);
      if (free < 0) {
        promotedList.add(to);
      } else {
        promotedList[free] = to;
      }
    }
    if (mover.role == Role.king && (from - to).abs() == 2) {
      final rookFrom = (to & 7) == 6 ? (from ~/ 8) * 8 + 7 : (from ~/ 8) * 8;
      final rookTo = (to & 7) == 6 ? to - 1 : to + 1;
      final rooks = _pieces[(side, Role.rook)]!;
      final rookSlot = rooks.indexOf(rookFrom);
      if (rookSlot < 0) {
        throw const CbhFormatException('CBH castling rook is missing.');
      }
      rooks[rookSlot] = rookTo;
    }
    _position = after;
    _san.add(san);
  }

  static int _mapSquare(int square) => ((square & 7) << 3) | (square >> 3);

  static (Role, int, int, bool)? _instruction(int code) {
    if (code >= 1 && code <= 8) {
      const king = [8, 9, 1, 57, 56, 63, 7, 15];
      return (Role.king, 0, king[code - 1], true);
    }
    for (final range in <(int, int, Role, int)>[
      (0x0b, 0x26, Role.queen, 0),
      (0x27, 0x34, Role.rook, 0),
      (0x35, 0x42, Role.rook, 1),
      (0x43, 0x50, Role.bishop, 0),
      (0x51, 0x5e, Role.bishop, 1),
      (0x5f, 0x66, Role.knight, 0),
      (0x67, 0x6e, Role.knight, 1),
      (0x8f, 0xaa, Role.queen, 1),
      (0xab, 0xc6, Role.queen, 2),
      (0xc7, 0xd4, Role.rook, 2),
      (0xd5, 0xe2, Role.bishop, 2),
      (0xe3, 0xea, Role.knight, 2),
    ]) {
      if (code >= range.$1 && code <= range.$2) {
        final offsetIndex = code - range.$1;
        final offsets = switch (range.$3) {
          Role.queen => _queenOffsets,
          Role.rook => _rookOffsets,
          Role.bishop => _bishopOffsets,
          Role.knight => _knightOffsets,
          _ => throw StateError('Unsupported CBH role'),
        };
        return (
          range.$3,
          range.$4,
          offsets[offsetIndex],
          range.$3 != Role.knight,
        );
      }
    }
    if (code >= 0x6f && code <= 0x8e) {
      final pawn = (code - 0x6f) ~/ 4;
      final kind = (code - 0x6f) % 4;
      final white =
          kind == 0
              ? 8
              : kind == 1
              ? 16
              : kind == 2
              ? 9
              : 7;
      return (Role.pawn, pawn, white, false);
    }
    return null;
  }

  static const _rookOffsets = [8, 16, 24, 32, 40, 48, 56, 1, 2, 3, 4, 5, 6, 7];
  static const _bishopOffsets = [
    9,
    18,
    27,
    36,
    45,
    54,
    63,
    57,
    50,
    43,
    36,
    29,
    22,
    15,
  ];
  static const _queenOffsets = [
    8,
    16,
    24,
    32,
    40,
    48,
    56,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    9,
    18,
    27,
    36,
    45,
    54,
    63,
    57,
    50,
    43,
    36,
    29,
    22,
    15,
  ];
  static const _knightOffsets = [10, 17, 15, 6, -10, -17, -15, -6];
}
