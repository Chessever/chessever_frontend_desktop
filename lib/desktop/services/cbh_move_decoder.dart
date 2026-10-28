import 'dart:convert';

import 'package:dartchess/dartchess.dart';

import 'cbh_frame_reader.dart';
import 'cbh_index_reader.dart';
import 'cbh_move_tables.dart';

/// Decodes classic-CBH move trees with an independent Dart board.
/// Unsupported opcodes fail the entire record.
final class CbhMoveDecoder {
  CbhMoveDecoder();

  Position _position = Chess.initial;
  final _pieces = <(Side, Role), List<int?>>{};
  final _san = <String>[];
  final _byAddress = <int, _CbhMoveNode>{};
  late _CbhMoveNode _root;
  late _CbhMoveNode _current;
  String? _startFen;

  String? get startFen => _startFen;

  String get movetext => _renderLine(_root, _startPly);
  int get decodedMoveCount {
    var count = 0;
    final pending = <_CbhMoveNode>[_root];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      count += node.children.length;
      pending.addAll(node.children);
    }
    return count;
  }

  int _startPly = 0;

  List<String> decode(CbhGameFrame frame) {
    if (frame.chess960) {
      throw const CbhFormatException('Chess960 positions are not decoded yet.');
    }
    _position = Chess.initial;
    _san.clear();
    _byAddress.clear();
    _root = _CbhMoveNode('');
    _current = _root;
    _startFen = null;
    _startPly = 0;
    if (frame.startingPosition case final bytes?) {
      _setupPosition(bytes);
    } else {
      _resetPieces();
    }
    final stack = <(Position, Map<(Side, Role), List<int?>>, _CbhMoveNode)>[];
    var moveNumber = 0;
    final bytes = frame.moveBytes;
    for (var cursor = 0; cursor < bytes.length; cursor++) {
      final code = cbhMoveLookup[(bytes[cursor] - moveNumber) & 255];
      if (code >= 0xec && code <= 0xfd) {
        throw CbhFormatException('Unsupported CBH move opcode $code.');
      }
      if (code == 0xfe) {
        if (stack.length >= 128) {
          throw const CbhFormatException('CBH variation depth exceeds 128.');
        }
        stack.add((_position, _copyPieces(), _current));
        continue;
      }
      if (code == 0xff) {
        if (stack.isEmpty) {
          // Some root games finish with a pop marker.
          if (cursor != bytes.length - 1) {
            throw const CbhFormatException('Unexpected CBH root pop.');
          }
          continue;
        }
        final (position, pieces, node) = stack.removeLast();
        _position = position;
        _pieces
          ..clear()
          ..addAll(pieces);
        _current = node;
        continue;
      }
      if (code == 0) {
        _position = _position.copyWith(
          turn: _position.turn == Side.white ? Side.black : Side.white,
          epSquare: null,
          halfmoves: _position.halfmoves + 1,
          fullmoves:
              _position.fullmoves + (_position.turn == Side.black ? 1 : 0),
        );
        final child = _CbhMoveNode('--');
        _current.children.add(child);
        _current = child;
        _byAddress[moveNumber] = child;
        moveNumber++;
        continue;
      }
      _address = moveNumber;
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
    if (stack.isNotEmpty) {
      throw const CbhFormatException('Unclosed CBH variation.');
    }
    var node = _root;
    while (node.children.isNotEmpty) {
      node = node.children.first;
      _san.add(node.san);
    }
    return List.unmodifiable(_san);
  }

  int _address = 0;

  /// Renders ordinary text comments while the complete source frame remains
  /// available for annotations PGN cannot express.
  void applyAnnotations(CbhAnnotationFrame frame) {
    for (final entry in frame.entries) {
      if (entry.type != 0x02 && entry.type != 0x82) continue;
      if (entry.payload.length < 2) {
        throw const CbhFormatException('Truncated CBH text annotation.');
      }
      final node =
          entry.moveAddress == 0xffffff ? _root : _byAddress[entry.moveAddress];
      if (node == null) continue; // Exact source frame remains archived.
      final bytes = entry.payload.sublist(2);
      final terminator = bytes.indexOf(0);
      final content = terminator < 0 ? bytes : bytes.sublist(0, terminator);
      if (content.isEmpty) continue;
      final rendered =
          _commentText(content)
              .replaceAll('{', '&#123;')
              .replaceAll('}', '&#125;')
              .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
              .trim();
      if (rendered.isEmpty) continue;
      if (node == _root || entry.type == 0x82) {
        node.before.add(rendered);
      } else {
        node.after.add(rendered);
      }
    }
  }

  static String _commentText(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      const cp1252 = <int, int>{
        0x80: 0x20ac,
        0x82: 0x201a,
        0x83: 0x0192,
        0x84: 0x201e,
        0x85: 0x2026,
        0x86: 0x2020,
        0x87: 0x2021,
        0x88: 0x02c6,
        0x89: 0x2030,
        0x8a: 0x0160,
        0x8b: 0x2039,
        0x8c: 0x0152,
        0x8e: 0x017d,
        0x91: 0x2018,
        0x92: 0x2019,
        0x93: 0x201c,
        0x94: 0x201d,
        0x95: 0x2022,
        0x96: 0x2013,
        0x97: 0x2014,
        0x98: 0x02dc,
        0x99: 0x2122,
        0x9a: 0x0161,
        0x9b: 0x203a,
        0x9c: 0x0153,
        0x9e: 0x017e,
        0x9f: 0x0178,
      };
      return String.fromCharCodes([
        for (final byte in bytes)
          if (byte >= 0x80 && byte <= 0x9f && !cp1252.containsKey(byte))
            0xfffd
          else
            cp1252[byte] ?? byte,
      ]);
    }
  }

  String _renderLine(_CbhMoveNode parent, int ply) {
    final output = StringBuffer();
    for (final comment in parent.before) {
      output.write('{$comment} ');
    }
    var first = true;
    var current = parent;
    var currentPly = ply;
    while (current.children.isNotEmpty) {
      final main = current.children.first;
      if (!first) output.write(' ');
      output.write(_renderMove(main, currentPly, first: first));
      for (final alternate in current.children.skip(1)) {
        output.write(' (');
        output.write(_renderBranch(alternate, currentPly));
        output.write(')');
      }
      current = main;
      currentPly++;
      first = false;
    }
    return output.toString();
  }

  String _renderBranch(_CbhMoveNode first, int ply) {
    final output = StringBuffer(_renderMove(first, ply, first: true));
    var current = first;
    var currentPly = ply + 1;
    while (current.children.isNotEmpty) {
      final main = current.children.first;
      output.write(' ${_renderMove(main, currentPly, first: false)}');
      for (final alternate in current.children.skip(1)) {
        output.write(' (${_renderBranch(alternate, currentPly)})');
      }
      current = main;
      currentPly++;
    }
    return output.toString();
  }

  static String _numbered(String san, int ply, {required bool first}) {
    if (ply.isEven) return '${ply ~/ 2 + 1}. $san';
    if (first) return '${ply ~/ 2 + 1}... $san';
    return san;
  }

  static String _renderMove(_CbhMoveNode node, int ply, {required bool first}) {
    final output = StringBuffer();
    for (final comment in node.before) {
      output.write('{$comment} ');
    }
    output.write(_numbered(node.san, ply, first: first));
    for (final comment in node.after) {
      output.write(' {$comment}');
    }
    return output.toString();
  }

  Map<(Side, Role), List<int?>> _copyPieces() => {
    for (final entry in _pieces.entries) entry.key: List<int?>.of(entry.value),
  };

  void _setupPosition(List<int> bytes) {
    if (bytes.length != 28) {
      throw const CbhFormatException('Invalid CBH starting position.');
    }
    var bit = 0;
    int read(int width) {
      var value = 0;
      for (var i = 0; i < width; i++) {
        value = (value << 1) | ((bytes[bit ~/ 8] >> (7 - bit % 8)) & 1);
        bit++;
      }
      return value;
    }

    bit = 11;
    final turn = read(1) == 0 ? Side.white : Side.black;
    final epFile = read(4);
    bit += 4;
    final blackShort = read(1) != 0;
    final blackLong = read(1) != 0;
    final whiteShort = read(1) != 0;
    final whiteLong = read(1) != 0;
    final fullmove = (read(8) - 1).clamp(1, 255);
    const roles = <Role?>[
      null,
      Role.king,
      Role.queen,
      Role.knight,
      Role.bishop,
      Role.rook,
      Role.pawn,
      null,
      null,
      Role.king,
      Role.queen,
      Role.knight,
      Role.bishop,
      Role.rook,
      Role.pawn,
      null,
    ];
    _pieces.clear();
    for (final side in Side.values) {
      for (final role in Role.values) {
        _pieces[(side, role)] = <int?>[];
      }
    }
    final board = List<String>.filled(64, '');
    for (var i = 0; i < 64; i++) {
      if (read(1) == 0) continue;
      final code = read(4);
      final role = roles[code];
      if (role == null) {
        throw const CbhFormatException('Invalid CBH starting piece.');
      }
      final side = code < 8 ? Side.white : Side.black;
      final square = _mapSquare(i);
      final symbol = switch (role) {
        Role.king => 'k',
        Role.queen => 'q',
        Role.rook => 'r',
        Role.bishop => 'b',
        Role.knight => 'n',
        Role.pawn => 'p',
      };
      board[square] = side == Side.white ? symbol.toUpperCase() : symbol;
      _pieces[(side, role)]!.add(square);
    }
    final ranks = <String>[];
    for (var rank = 7; rank >= 0; rank--) {
      final out = StringBuffer();
      var empty = 0;
      for (var file = 0; file < 8; file++) {
        final piece = board[rank * 8 + file];
        if (piece.isEmpty) {
          empty++;
        } else {
          if (empty != 0) out.write(empty);
          empty = 0;
          out.write(piece);
        }
      }
      if (empty != 0) out.write(empty);
      ranks.add(out.toString());
    }
    final castles =
        [
          if (whiteShort) 'K',
          if (whiteLong) 'Q',
          if (blackShort) 'k',
          if (blackLong) 'q',
        ].join();
    final ep =
        epFile == 0
            ? '-'
            : '${String.fromCharCode(96 + epFile)}${turn == Side.white ? 6 : 3}';
    final fen =
        '${ranks.join('/')} ${turn == Side.white ? 'w' : 'b'} '
        '${castles.isEmpty ? '-' : castles} $ep 0 $fullmove';
    try {
      _position = Position.setupPosition(Rule.chess, Setup.parseFen(fen));
    } on Object {
      throw const CbhFormatException('Invalid CBH starting position.');
    }
    _startFen = fen;
    _startPly = (fullmove - 1) * 2 + (turn == Side.black ? 1 : 0);
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
    final child = _CbhMoveNode(san);
    _current.children.add(child);
    _current = child;
    _byAddress[_address] = child;
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

final class _CbhMoveNode {
  _CbhMoveNode(this.san);
  final String san;
  final List<_CbhMoveNode> children = [];
  final List<String> before = [];
  final List<String> after = [];
}
