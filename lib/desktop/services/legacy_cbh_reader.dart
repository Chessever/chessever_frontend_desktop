import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartchess/dartchess.dart'
    show Chess, Move, Position, Setup, Side;
import 'package:path/path.dart' as p;

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

class LegacyCbhReadException implements Exception {
  const LegacyCbhReadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LegacyCbhGame {
  const LegacyCbhGame({
    required this.game,
    required this.rawPgn,
    required this.hasMoves,
  });

  final ChessGame game;
  final String rawPgn;
  final bool hasMoves;
}

List<LegacyCbhGame> readLegacyCbhGamesSync(
  String cbhPath, {
  required int maxGames,
}) {
  return _LegacyCbhReader(cbhPath, maxGames: maxGames).read();
}

class _LegacyCbhReader {
  _LegacyCbhReader(this.cbhPath, {required this.maxGames});

  final String cbhPath;
  final int maxGames;

  List<LegacyCbhGame> read() {
    final cbhFile = File(cbhPath);
    if (!cbhFile.existsSync()) {
      throw LegacyCbhReadException('CBH database file does not exist.');
    }

    final basePath = p.withoutExtension(cbhPath);
    final cbgPath = _resolveSibling(basePath, '.cbg');
    if (cbgPath == null) {
      throw const LegacyCbhReadException(
        'This .cbh file is only the reference database header. Open it from the folder '
        'that also contains the matching .cbg moves file.',
      );
    }

    final cbpPath = _resolveSibling(basePath, '.cbp');
    final cbtPath = _resolveSibling(basePath, '.cbt');
    final cbh = cbhFile.openSync();
    final cbg = File(cbgPath).openSync();
    final cbp = cbpPath == null ? null : File(cbpPath).openSync();
    final cbt = cbtPath == null ? null : File(cbtPath).openSync();

    try {
      final cbpVersion = cbp == null ? null : _readVersionByte(cbp);
      final cbtVersion = cbt == null ? null : _readVersionByte(cbt);
      final recordCount = cbh.lengthSync() ~/ _cbhRecordSize;
      final out = <LegacyCbhGame>[];

      for (var i = 1; i < recordCount && out.length < maxGames; i++) {
        final record = _readAtSync(cbh, i * _cbhRecordSize, _cbhRecordSize);
        if (!_isGame(record) || _isDeleted(record)) continue;

        final gameOffset = _u32(record, 1);
        final info = _readGameInfo(cbg, gameOffset);
        if (info.isEncoded || info.isChess960 || info.hasSpecialEncoding) {
          continue;
        }

        final decoded = _decodeGame(cbg, gameOffset, info);
        if (decoded.mainline.isEmpty) continue;

        final metadata = <String, String>{};
        metadata['Event'] =
            _readTournamentTitle(cbt, cbtVersion, record) ?? '?';
        metadata['Site'] = _readTournamentPlace(cbt, cbtVersion, record) ?? '?';
        metadata['Date'] = _dateTag(record);
        metadata['Round'] = _roundTag(record);
        metadata['White'] =
            _readPlayerName(cbp, cbpVersion, _whitePlayerOffset(record)) ?? '?';
        metadata['Black'] =
            _readPlayerName(cbp, cbpVersion, _blackPlayerOffset(record)) ?? '?';
        metadata['Result'] = _resultTag(record);

        final whiteElo = _u16(record, 31);
        final blackElo = _u16(record, 33);
        if (whiteElo > 0) metadata['WhiteElo'] = '$whiteElo';
        if (blackElo > 0) metadata['BlackElo'] = '$blackElo';

        final rawPgn = _pgnFromMoves(
          metadata,
          decoded.mainline,
          startingFen: decoded.startingFen,
        );
        try {
          final game = ChessGame.fromPgn('cbh_$i', rawPgn);
          out.add(
            LegacyCbhGame(
              game: game,
              rawPgn: rawPgn,
              hasMoves: game.mainline.isNotEmpty,
            ),
          );
        } catch (_) {
          // If SAN materialization exposes a malformed legacy record, skip it
          // and keep the rest of the database usable.
        }
      }

      return out;
    } finally {
      cbh.closeSync();
      cbg.closeSync();
      cbp?.closeSync();
      cbt?.closeSync();
    }
  }
}

const int _cbhRecordSize = 46;
const int _maskStartWithInitial = 0x40000000;
const int _maskIsEncoded = 0x80000000;
const int _maskSpecialEncoding = 0x04000000;
const int _maskIs960 = 0x0A000000;
const int _maskGameLength = 0x00FFFFFF;
const int _maskMarkedForDeletion = 0x80;
const int _maskIsGame = 0x01;

_GameInfo _readGameInfo(RandomAccessFile cbg, int offset) {
  final bytes = _readAtSync(cbg, offset, 4);
  final sizeInfo = _u32(bytes, 0);
  return _GameInfo(
    startsFromCustomPosition: (sizeInfo & _maskStartWithInitial) != 0,
    isEncoded: (sizeInfo & _maskIsEncoded) != 0,
    isChess960: (sizeInfo & _maskIs960) != 0,
    hasSpecialEncoding: (sizeInfo & _maskSpecialEncoding) != 0,
    gameLength: sizeInfo & _maskGameLength,
  );
}

_DecodedCbhGame _decodeGame(
  RandomAccessFile cbg,
  int gameOffset,
  _GameInfo info,
) {
  if (info.gameLength <= 4) {
    throw const LegacyCbhReadException('CBH game record is empty.');
  }

  late final _BoardState state;
  late final String? startingFen;
  late final int payloadOffset;
  if (info.startsFromCustomPosition) {
    final setup = _readAtSync(cbg, gameOffset + 4, 28);
    state = _stateFromSetupBytes(setup);
    startingFen = state.toFen();
    payloadOffset = gameOffset + 32;
  } else {
    state = _BoardState.initial();
    startingFen = null;
    payloadOffset = gameOffset + 4;
  }

  final payloadLength = info.gameLength - (payloadOffset - gameOffset);
  if (payloadLength <= 0) {
    return _DecodedCbhGame(
      mainline: const <_DecodedCbhMove>[],
      startingFen: startingFen,
    );
  }
  final payload = _readAtSync(cbg, payloadOffset, payloadLength);
  return _DecodedCbhGame(
    mainline: _decodeMovePayload(payload, state),
    startingFen: startingFen,
  );
}

List<_DecodedCbhMove> _decodeMovePayload(
  Uint8List bytes,
  _BoardState initialState,
) {
  final mainline = <_DecodedCbhMove>[];
  final stack = <_VariationFrame>[];
  var currentLine = mainline;
  var state = initialState;
  var processedMoves = 0;
  var index = 0;

  while (index < bytes.length) {
    final token = (bytes[index] - processedMoves) & 0xFF;
    if (!_isSpecialToken(token)) {
      processedMoves = (processedMoves + 1) & 0xFF;
    }

    if (token == 0x9F) {
      index += 1;
      continue;
    }

    if (token == 0xAA) {
      state.whiteToMove = !state.whiteToMove;
      index += 1;
      continue;
    }

    if (token == 0x29) {
      if (index + 2 >= bytes.length) break;
      final uci = _decodeTwoByteMove(
        state,
        bytes[index + 1],
        bytes[index + 2],
        processedMoves,
      );
      final move = _DecodedCbhMove(uci);
      currentLine.add(move);
      processedMoves = (processedMoves + 1) & 0xFF;
      index += 3;
      continue;
    }

    if (token == 0xDC) {
      if (currentLine.isEmpty) {
        stack.add(_VariationFrame(state.clone(), currentLine));
        currentLine = <_DecodedCbhMove>[];
      } else {
        final variation = <_DecodedCbhMove>[];
        currentLine.last.variations.add(variation);
        stack.add(_VariationFrame(state.clone(), currentLine));
        currentLine = variation;
      }
      index += 1;
      continue;
    }

    if (token == 0x0C) {
      if (index < bytes.length - 1 && stack.isNotEmpty) {
        final frame = stack.removeLast();
        state = frame.state;
        currentLine = frame.line;
      }
      index += 1;
      continue;
    }

    final uci = _decodeOneByteMove(state, token);
    currentLine.add(_DecodedCbhMove(uci));
    index += 1;
  }

  return mainline;
}

bool _isSpecialToken(int token) =>
    token == 0x29 || token == 0xDC || token == 0x0C || token == 0x9F;

String _decodeOneByteMove(_BoardState state, int token) {
  final white = state.whiteToMove;
  final candidates = white
      ? const <_MoveEncoding>[
          _MoveEncoding(_wKing, 0, _cbKingEnc),
          _MoveEncoding(_wQueen, 0, _cbQueen1Enc),
          _MoveEncoding(_wQueen, 1, _cbQueen2Enc),
          _MoveEncoding(_wQueen, 2, _cbQueen3Enc),
          _MoveEncoding(_wRook, 0, _cbRook1Enc),
          _MoveEncoding(_wRook, 1, _cbRook2Enc),
          _MoveEncoding(_wRook, 2, _cbRook3Enc),
          _MoveEncoding(_wBishop, 0, _cbBishop1Enc),
          _MoveEncoding(_wBishop, 1, _cbBishop2Enc),
          _MoveEncoding(_wBishop, 2, _cbBishop3Enc),
          _MoveEncoding(_wKnight, 0, _cbKnight1Enc),
          _MoveEncoding(_wKnight, 1, _cbKnight2Enc),
          _MoveEncoding(_wKnight, 2, _cbKnight3Enc),
          _MoveEncoding(_wPawn, 0, _cbPawnAEnc),
          _MoveEncoding(_wPawn, 1, _cbPawnBEnc),
          _MoveEncoding(_wPawn, 2, _cbPawnCEnc),
          _MoveEncoding(_wPawn, 3, _cbPawnDEnc),
          _MoveEncoding(_wPawn, 4, _cbPawnEEnc),
          _MoveEncoding(_wPawn, 5, _cbPawnFEnc),
          _MoveEncoding(_wPawn, 6, _cbPawnGEnc),
          _MoveEncoding(_wPawn, 7, _cbPawnHEnc),
        ]
      : const <_MoveEncoding>[
          _MoveEncoding(_bKing, 0, _cbKingEnc),
          _MoveEncoding(_bQueen, 0, _cbQueen1Enc),
          _MoveEncoding(_bQueen, 1, _cbQueen2Enc),
          _MoveEncoding(_bQueen, 2, _cbQueen3Enc),
          _MoveEncoding(_bRook, 0, _cbRook1Enc),
          _MoveEncoding(_bRook, 1, _cbRook2Enc),
          _MoveEncoding(_bRook, 2, _cbRook3Enc),
          _MoveEncoding(_bBishop, 0, _cbBishop1Enc),
          _MoveEncoding(_bBishop, 1, _cbBishop2Enc),
          _MoveEncoding(_bBishop, 2, _cbBishop3Enc),
          _MoveEncoding(_bKnight, 0, _cbKnight1Enc),
          _MoveEncoding(_bKnight, 1, _cbKnight2Enc),
          _MoveEncoding(_bKnight, 2, _cbKnight3Enc),
          _MoveEncoding(_bPawn, 0, _cbPawnAEnc, pawnFlip: true),
          _MoveEncoding(_bPawn, 1, _cbPawnBEnc, pawnFlip: true),
          _MoveEncoding(_bPawn, 2, _cbPawnCEnc, pawnFlip: true),
          _MoveEncoding(_bPawn, 3, _cbPawnDEnc, pawnFlip: true),
          _MoveEncoding(_bPawn, 4, _cbPawnEEnc, pawnFlip: true),
          _MoveEncoding(_bPawn, 5, _cbPawnFEnc, pawnFlip: true),
          _MoveEncoding(_bPawn, 6, _cbPawnGEnc, pawnFlip: true),
          _MoveEncoding(_bPawn, 7, _cbPawnHEnc, pawnFlip: true),
        ];

  for (final candidate in candidates) {
    final delta = candidate.table[token];
    if (delta == null) continue;
    return state.applyOneByteMove(
      pieceType: candidate.pieceType,
      pieceNumber: candidate.pieceNumber,
      token: token,
      delta: delta,
      pawnFlip: candidate.pawnFlip,
    );
  }

  throw LegacyCbhReadException(
    'Unsupported CBH move token 0x${token.toRadixString(16)}.',
  );
}

String _decodeTwoByteMove(
  _BoardState state,
  int first,
  int second,
  int processedMoves,
) {
  final hi = _deobfuscate2b[(first - processedMoves) & 0xFF];
  final lo = _deobfuscate2b[(second - processedMoves) & 0xFF];
  final packed = (hi << 8) | lo;
  final src = packed & 0x3F;
  final dst = (packed >> 6) & 0x3F;
  final promotion = (packed >> 12) & 0x03;
  final from = _absoluteToSquare(src);
  final to = _absoluteToSquare(dst);
  return state.applyTwoByteMove(from, to, promotion);
}

_BoardState _stateFromSetupBytes(Uint8List setup) {
  final epFile = setup[1] & 0x07;
  final blackToMove = (setup[1] & 0x10) != 0;
  final whiteCastleLong = (setup[2] & 0x01) != 0;
  final whiteCastleShort = (setup[2] & 0x02) != 0;
  final blackCastleLong = (setup[2] & 0x04) != 0;
  final blackCastleShort = (setup[2] & 0x08) != 0;
  final nextMoveNo = setup[3] == 0 ? 1 : setup[3];
  final state = _decodePieceLocations(setup.sublist(4, 28));
  state
    ..whiteToMove = !blackToMove
    ..epFile = epFile
    ..whiteCastleLong = whiteCastleLong
    ..whiteCastleShort = whiteCastleShort
    ..blackCastleLong = blackCastleLong
    ..blackCastleShort = blackCastleShort
    ..nextMoveNumber = nextMoveNo;
  return state;
}

_BoardState _decodePieceLocations(Uint8List bytes) {
  final state = _BoardState.empty();
  var bitIndex = 0;
  var boardIndex = 0;

  int bitAt(int index) {
    final byte = bytes[index ~/ 8];
    return (byte >> (7 - (index % 8))) & 1;
  }

  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 1) | bitAt(bitIndex + i);
    }
    bitIndex += count;
    return value;
  }

  while (bitIndex < bytes.length * 8 && boardIndex < 64) {
    final occupied = readBits(1) == 1;
    if (!occupied) {
      boardIndex += 1;
      continue;
    }

    if (bitIndex + 4 > bytes.length * 8) break;
    final code = readBits(4);
    final square = _absoluteToSquare(boardIndex);
    final pieceType = switch (code) {
      0x01 => _wKing,
      0x02 => _wQueen,
      0x03 => _wKnight,
      0x04 => _wBishop,
      0x05 => _wRook,
      0x06 => _wPawn,
      0x09 => _bKing,
      0x0A => _bQueen,
      0x0B => _bKnight,
      0x0C => _bBishop,
      0x0D => _bRook,
      0x0E => _bPawn,
      _ => throw LegacyCbhReadException(
        'Unsupported CBH setup piece code $code.',
      ),
    };
    state.placePiece(pieceType, square);
    boardIndex += 1;
  }

  state.padPieceLists();
  return state;
}

String _pgnFromMoves(
  Map<String, String> headers,
  List<_DecodedCbhMove> mainline, {
  String? startingFen,
}) {
  final normalizedHeaders = <String, String>{
    'Event': headers['Event']?.trim().isNotEmpty == true
        ? headers['Event']!
        : '?',
    'Site': headers['Site']?.trim().isNotEmpty == true ? headers['Site']! : '?',
    'Date': headers['Date'] ?? '????.??.??',
    'Round': headers['Round']?.trim().isNotEmpty == true
        ? headers['Round']!
        : '?',
    'White': headers['White']?.trim().isNotEmpty == true
        ? headers['White']!
        : '?',
    'Black': headers['Black']?.trim().isNotEmpty == true
        ? headers['Black']!
        : '?',
    'Result': headers['Result'] ?? '*',
    if (startingFen != null) 'SetUp': '1',
    if (startingFen != null) 'FEN': startingFen,
    if (headers['WhiteElo'] != null) 'WhiteElo': headers['WhiteElo']!,
    if (headers['BlackElo'] != null) 'BlackElo': headers['BlackElo']!,
  };

  final out = StringBuffer();
  for (final entry in normalizedHeaders.entries) {
    out.writeln('[${entry.key} "${_escapePgnHeader(entry.value)}"]');
  }
  out.writeln();
  out.write(_movetextFromDecodedLine(mainline, startingFen: startingFen));
  out.write(' ${normalizedHeaders['Result']}');
  return out.toString().trim();
}

String _movetextFromDecodedLine(
  List<_DecodedCbhMove> line, {
  String? startingFen,
}) {
  final position = startingFen == null
      ? Chess.initial
      : Chess.fromSetup(
          Setup.parseFen(startingFen),
          ignoreImpossibleCheck: true,
        );
  return _movetextFromDecodedLineAtPosition(line, position);
}

String _movetextFromDecodedLineAtPosition(
  List<_DecodedCbhMove> line,
  Position startingPosition,
) {
  var position = startingPosition;
  final out = <String>[];
  var pendingVariations = const <List<_DecodedCbhMove>>[];
  Position? pendingVariationPosition;

  void flushPendingVariations() {
    final variationPosition = pendingVariationPosition;
    if (variationPosition == null) return;
    for (final variation in pendingVariations) {
      final variationText = _movetextFromDecodedLineAtPosition(
        variation,
        variationPosition,
      );
      if (variationText.isNotEmpty) out.add('($variationText)');
    }
    pendingVariations = const <List<_DecodedCbhMove>>[];
    pendingVariationPosition = null;
  }

  for (final node in line) {
    final move = Move.parse(node.uci);
    if (move == null) {
      throw LegacyCbhReadException('Invalid decoded UCI move ${node.uci}.');
    }
    final made = position.makeSan(move);
    final san = made.$2;
    if (position.turn == Side.white) {
      out.add('${position.fullmoves}. $san');
    } else if (out.isEmpty) {
      out.add('${position.fullmoves}... $san');
    } else {
      out.add(san);
    }

    flushPendingVariations();

    final nextPosition = made.$1;
    pendingVariations = node.variations;
    pendingVariationPosition = nextPosition;
    position = nextPosition;
  }

  flushPendingVariations();

  return out.join(' ');
}

String _escapePgnHeader(String value) =>
    value.replaceAll('\\', r'\\').replaceAll('"', r'\"');

String? _resolveSibling(String basePath, String extension) {
  for (final candidate in <String>[
    '$basePath$extension',
    '$basePath${extension.toUpperCase()}',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }

  final directory = Directory(p.dirname(basePath));
  if (!directory.existsSync()) return null;
  final stem = p.basename(basePath).toLowerCase();
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is! File) continue;
    if (p.basenameWithoutExtension(entity.path).toLowerCase() == stem &&
        p.extension(entity.path).toLowerCase() == extension) {
      return entity.path;
    }
  }
  return null;
}

Uint8List _readAtSync(RandomAccessFile file, int offset, int length) {
  file.setPositionSync(offset);
  return file.readSync(length);
}

int? _readVersionByte(RandomAccessFile file) {
  if (file.lengthSync() <= 0x18) return null;
  file.setPositionSync(0x18);
  return file.readByteSync();
}

int _u16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _u24(Uint8List bytes, int offset) =>
    (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];

int _u32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

bool _isGame(Uint8List record) => (record[0] & _maskIsGame) != 0;

bool _isDeleted(Uint8List record) => (record[0] & _maskMarkedForDeletion) != 0;

int _whitePlayerOffset(Uint8List record) => _u24(record, 9);

int _blackPlayerOffset(Uint8List record) => _u24(record, 12);

int _tournamentOffset(Uint8List record) => _u24(record, 15);

String _dateTag(Uint8List record) {
  final packed = _u24(record, 24);
  final year = (packed & 0xFFFE00) >> 9;
  final month = (packed & 0x01E0) >> 5;
  final day = packed & 0x001F;
  return '${year == 0 ? '????' : year.toString().padLeft(4, '0')}.'
      '${month == 0 ? '??' : month.toString().padLeft(2, '0')}.'
      '${day == 0 ? '??' : day.toString().padLeft(2, '0')}';
}

String _roundTag(Uint8List record) {
  final round = record[29];
  final subround = record[30];
  if (round == 0 && subround == 0) return '?';
  if (subround != 0) return '$round($subround)';
  return '$round';
}

String _resultTag(Uint8List record) {
  return switch (record[27]) {
    2 => '1-0',
    1 => '1/2-1/2',
    0 => '0-1',
    _ => '*',
  };
}

String? _readPlayerName(
  RandomAccessFile? file,
  int? version,
  int playerNumber,
) {
  if (file == null || version == null) return null;
  final recordOffset = switch (version) {
    4 => 32 + (playerNumber * 67),
    0 => 28 + (playerNumber * 67),
    _ => null,
  };
  if (recordOffset == null || file.lengthSync() < recordOffset + 67) {
    return null;
  }
  final record = _readAtSync(file, recordOffset, 67);
  final last = _decodeNullTerminated(record, 9, 30);
  final first = _decodeNullTerminated(record, 39, 20);
  if (last.isEmpty) return first.isEmpty ? null : first;
  if (first.isEmpty) return last;
  return '$last, $first';
}

String? _readTournamentTitle(
  RandomAccessFile? file,
  int? version,
  Uint8List record,
) {
  return _readTournamentField(file, version, record, 9, 40);
}

String? _readTournamentPlace(
  RandomAccessFile? file,
  int? version,
  Uint8List record,
) {
  return _readTournamentField(file, version, record, 49, 30);
}

String? _readTournamentField(
  RandomAccessFile? file,
  int? version,
  Uint8List record,
  int fieldOffset,
  int length,
) {
  if (file == null || version == null) return null;
  final tournamentNumber = _tournamentOffset(record);
  final recordOffset = switch (version) {
    4 => 32 + (tournamentNumber * 99),
    0 => 28 + (tournamentNumber * 99),
    _ => null,
  };
  if (recordOffset == null || file.lengthSync() < recordOffset + 99) {
    return null;
  }
  final tournament = _readAtSync(file, recordOffset, 99);
  final value = _decodeNullTerminated(tournament, fieldOffset, length);
  return value.isEmpty ? null : value;
}

String _decodeNullTerminated(Uint8List bytes, int offset, int length) {
  final end = offset + length;
  var zero = end;
  for (var i = offset; i < end; i++) {
    if (bytes[i] == 0) {
      zero = i;
      break;
    }
  }
  return utf8.decode(bytes.sublist(offset, zero), allowMalformed: true).trim();
}

class _GameInfo {
  const _GameInfo({
    required this.startsFromCustomPosition,
    required this.isEncoded,
    required this.isChess960,
    required this.hasSpecialEncoding,
    required this.gameLength,
  });

  final bool startsFromCustomPosition;
  final bool isEncoded;
  final bool isChess960;
  final bool hasSpecialEncoding;
  final int gameLength;
}

class _DecodedCbhGame {
  const _DecodedCbhGame({required this.mainline, required this.startingFen});

  final List<_DecodedCbhMove> mainline;
  final String? startingFen;
}

class _DecodedCbhMove {
  _DecodedCbhMove(this.uci);

  final String uci;
  final List<List<_DecodedCbhMove>> variations = <List<_DecodedCbhMove>>[];
}

class _VariationFrame {
  const _VariationFrame(this.state, this.line);

  final _BoardState state;
  final List<_DecodedCbhMove> line;
}

class _Delta {
  const _Delta(this.x, this.y);

  final int x;
  final int y;
}

class _MoveEncoding {
  const _MoveEncoding(
    this.pieceType,
    this.pieceNumber,
    this.table, {
    this.pawnFlip = false,
  });

  final int pieceType;
  final int pieceNumber;
  final Map<int, _Delta> table;
  final bool pawnFlip;
}

class _Square {
  const _Square(this.file, this.rank);

  final int file;
  final int rank;

  String get name => '${String.fromCharCode(97 + file)}${rank + 1}';
}

class _PieceRef {
  const _PieceRef(this.type, this.number);

  final int type;
  final int? number;
}

class _BoardState {
  _BoardState({
    required this.board,
    required this.pieces,
    required this.whiteToMove,
    this.epFile = 0,
    this.whiteCastleLong = false,
    this.whiteCastleShort = false,
    this.blackCastleLong = false,
    this.blackCastleShort = false,
    this.nextMoveNumber = 1,
  });

  factory _BoardState.empty() {
    return _BoardState(
      board: List.generate(8, (_) => List<_PieceRef>.filled(8, _emptyPiece)),
      pieces: List.generate(13, (_) => <_Square?>[]),
      whiteToMove: true,
    );
  }

  factory _BoardState.initial() {
    final state = _BoardState.empty()
      ..whiteCastleLong = true
      ..whiteCastleShort = true
      ..blackCastleLong = true
      ..blackCastleShort = true;
    for (var file = 0; file < 8; file++) {
      state.placePiece(_wPawn, _Square(file, 1), preferredNumber: file);
      state.placePiece(_bPawn, _Square(file, 6), preferredNumber: file);
    }
    state.placePiece(_wRook, const _Square(0, 0), preferredNumber: 0);
    state.placePiece(_wKnight, const _Square(1, 0), preferredNumber: 0);
    state.placePiece(_wBishop, const _Square(2, 0), preferredNumber: 0);
    state.placePiece(_wQueen, const _Square(3, 0), preferredNumber: 0);
    state.placePiece(_wKing, const _Square(4, 0), preferredNumber: 0);
    state.placePiece(_wBishop, const _Square(5, 0), preferredNumber: 1);
    state.placePiece(_wKnight, const _Square(6, 0), preferredNumber: 1);
    state.placePiece(_wRook, const _Square(7, 0), preferredNumber: 1);
    state.placePiece(_bRook, const _Square(0, 7), preferredNumber: 0);
    state.placePiece(_bKnight, const _Square(1, 7), preferredNumber: 0);
    state.placePiece(_bBishop, const _Square(2, 7), preferredNumber: 0);
    state.placePiece(_bQueen, const _Square(3, 7), preferredNumber: 0);
    state.placePiece(_bKing, const _Square(4, 7), preferredNumber: 0);
    state.placePiece(_bBishop, const _Square(5, 7), preferredNumber: 1);
    state.placePiece(_bKnight, const _Square(6, 7), preferredNumber: 1);
    state.placePiece(_bRook, const _Square(7, 7), preferredNumber: 1);
    state.padPieceLists();
    return state;
  }

  List<List<_PieceRef>> board;
  List<List<_Square?>> pieces;
  bool whiteToMove;
  int epFile;
  bool whiteCastleLong;
  bool whiteCastleShort;
  bool blackCastleLong;
  bool blackCastleShort;
  int nextMoveNumber;

  _BoardState clone() {
    return _BoardState(
      board: [for (final file in board) List<_PieceRef>.of(file)],
      pieces: [for (final list in pieces) List<_Square?>.of(list)],
      whiteToMove: whiteToMove,
      epFile: epFile,
      whiteCastleLong: whiteCastleLong,
      whiteCastleShort: whiteCastleShort,
      blackCastleLong: blackCastleLong,
      blackCastleShort: blackCastleShort,
      nextMoveNumber: nextMoveNumber,
    );
  }

  void placePiece(int pieceType, _Square square, {int? preferredNumber}) {
    final list = pieces[pieceType];
    final number = preferredNumber ?? list.length;
    while (list.length <= number) {
      list.add(null);
    }
    list[number] = square;
    board[square.file][square.rank] = _PieceRef(pieceType, number);
  }

  void padPieceLists() {
    for (var type = _wQueen; type <= _bRook; type++) {
      while (pieces[type].length < 8) {
        pieces[type].add(null);
      }
    }
    for (final type in <int>[_wPawn, _bPawn]) {
      while (pieces[type].length < 8) {
        pieces[type].add(null);
      }
    }
    for (final type in <int>[_wKing, _bKing]) {
      while (pieces[type].isEmpty) {
        pieces[type].add(null);
      }
    }
  }

  String applyOneByteMove({
    required int pieceType,
    required int pieceNumber,
    required int token,
    required _Delta delta,
    required bool pawnFlip,
  }) {
    final from = _pieceSquare(pieceType, pieceNumber);
    board[from.file][from.rank] = _emptyPiece;
    final dx = pawnFlip ? -delta.x : delta.x;
    final dy = pawnFlip ? -delta.y : delta.y;
    final to = _Square((from.file + dx) % 8, (from.rank + dy) % 8);
    _captureTargetAt(to);
    board[to.file][to.rank] = _PieceRef(pieceType, pieceNumber);
    pieces[pieceType][pieceNumber] = to;
    _moveCastlingRookIfNeeded(pieceType, token);
    whiteToMove = !whiteToMove;
    return '${from.name}${to.name}';
  }

  String applyTwoByteMove(_Square from, _Square to, int promotionCode) {
    final ref = board[from.file][from.rank];
    if (ref.type == 0 || ref.number == null) {
      throw LegacyCbhReadException(
        'CBH move starts from an empty square: ${from.name}.',
      );
    }
    board[from.file][from.rank] = _emptyPiece;
    _captureTargetAt(to);

    var promotion = '';
    final promotedType = _promotedPieceType(ref.type, to.rank, promotionCode);
    if (promotedType == null) {
      board[to.file][to.rank] = _PieceRef(ref.type, ref.number);
      pieces[ref.type][ref.number!] = to;
    } else {
      promotion = _promotionSuffix(promotionCode);
      final number = _firstFreePieceNumber(promotedType);
      pieces[promotedType][number] = to;
      board[to.file][to.rank] = _PieceRef(promotedType, number);
    }

    whiteToMove = !whiteToMove;
    return '${from.name}${to.name}$promotion';
  }

  String toFen() {
    final out = StringBuffer();
    for (var rank = 7; rank >= 0; rank--) {
      var empty = 0;
      for (var file = 0; file < 8; file++) {
        final piece = board[file][rank].type;
        if (piece == 0) {
          empty += 1;
          continue;
        }
        if (empty > 0) {
          out.write(empty);
          empty = 0;
        }
        out.write(_fenPiece(piece));
      }
      if (empty > 0) out.write(empty);
      if (rank > 0) out.write('/');
    }
    out.write(whiteToMove ? ' w ' : ' b ');
    final castling = StringBuffer();
    if (whiteCastleShort) castling.write('K');
    if (whiteCastleLong) castling.write('Q');
    if (blackCastleShort) castling.write('k');
    if (blackCastleLong) castling.write('q');
    out.write(castling.isEmpty ? '-' : castling.toString());
    if (epFile > 0) {
      out.write(' ${String.fromCharCode(96 + epFile)}');
      out.write(whiteToMove ? '6' : '3');
    } else {
      out.write(' -');
    }
    out.write(' 0 $nextMoveNumber');
    return out.toString();
  }

  _Square _pieceSquare(int pieceType, int pieceNumber) {
    if (pieces[pieceType].length <= pieceNumber ||
        pieces[pieceType][pieceNumber] == null) {
      throw LegacyCbhReadException(
        'reference database piece $pieceType/$pieceNumber is missing.',
      );
    }
    return pieces[pieceType][pieceNumber]!;
  }

  void _captureTargetAt(_Square to) {
    final target = board[to.file][to.rank];
    if (target.type == 0 ||
        target.type == _wKing ||
        target.type == _bKing ||
        target.type == _wPawn ||
        target.type == _bPawn ||
        target.number == null) {
      return;
    }
    _decreasePieceNumber(target.type, target.number!);
  }

  void _decreasePieceNumber(int pieceType, int number) {
    final list = pieces[pieceType];
    for (var i = number; i < 7 && i + 1 < list.length; i++) {
      list[i] = list[i + 1];
    }
    if (list.length >= 8) list[7] = null;
    for (var file = 0; file < 8; file++) {
      for (var rank = 0; rank < 8; rank++) {
        final ref = board[file][rank];
        if (ref.type == pieceType &&
            ref.number != null &&
            ref.number! > number) {
          board[file][rank] = _PieceRef(pieceType, ref.number! - 1);
        }
      }
    }
  }

  void _moveCastlingRookIfNeeded(int pieceType, int token) {
    if (token == 0x76 && pieceType == _wKing) {
      _relocateRook(_wRook, const _Square(7, 0), const _Square(5, 0));
    } else if (token == 0x76 && pieceType == _bKing) {
      _relocateRook(_bRook, const _Square(7, 7), const _Square(5, 7));
    } else if (token == 0xB5 && pieceType == _wKing) {
      _relocateRook(_wRook, const _Square(0, 0), const _Square(3, 0));
    } else if (token == 0xB5 && pieceType == _bKing) {
      _relocateRook(_bRook, const _Square(0, 7), const _Square(3, 7));
    }
  }

  void _relocateRook(int pieceType, _Square from, _Square to) {
    board[from.file][from.rank] = _emptyPiece;
    for (var i = 0; i < pieces[pieceType].length; i++) {
      final square = pieces[pieceType][i];
      if (square != null &&
          square.file == from.file &&
          square.rank == from.rank) {
        pieces[pieceType][i] = to;
        board[to.file][to.rank] = _PieceRef(pieceType, i);
        return;
      }
    }
  }

  int? _promotedPieceType(int pieceType, int targetRank, int promotionCode) {
    if (pieceType == _wPawn && targetRank == 7) {
      return switch (promotionCode) {
        0 => _wQueen,
        1 => _wRook,
        2 => _wBishop,
        3 => _wKnight,
        _ => null,
      };
    }
    if (pieceType == _bPawn && targetRank == 0) {
      return switch (promotionCode) {
        0 => _bQueen,
        1 => _bRook,
        2 => _bBishop,
        3 => _bKnight,
        _ => null,
      };
    }
    return null;
  }

  int _firstFreePieceNumber(int pieceType) {
    final list = pieces[pieceType];
    for (var i = 0; i < list.length; i++) {
      if (list[i] == null) return i;
    }
    list.add(null);
    return list.length - 1;
  }
}

const _emptyPiece = _PieceRef(0, null);

_Square _absoluteToSquare(int index) => _Square(index ~/ 8, index % 8);

String _promotionSuffix(int promotionCode) {
  return switch (promotionCode) {
    0 => 'q',
    1 => 'r',
    2 => 'b',
    3 => 'n',
    _ => throw LegacyCbhReadException('Unknown promotion code $promotionCode.'),
  };
}

String _fenPiece(int pieceType) {
  return switch (pieceType) {
    _wKing => 'K',
    _wQueen => 'Q',
    _wRook => 'R',
    _wBishop => 'B',
    _wKnight => 'N',
    _wPawn => 'P',
    _bKing => 'k',
    _bQueen => 'q',
    _bRook => 'r',
    _bBishop => 'b',
    _bKnight => 'n',
    _bPawn => 'p',
    _ => throw LegacyCbhReadException('Unknown piece type $pieceType.'),
  };
}

const int _wQueen = 1;
const int _wKnight = 2;
const int _wBishop = 3;
const int _wRook = 4;
const int _bQueen = 5;
const int _bKnight = 6;
const int _bBishop = 7;
const int _bRook = 8;
const int _wKing = 9;
const int _bKing = 10;
const int _wPawn = 11;
const int _bPawn = 12;

// Move decoding tables derived from asdfjkl/cbh2pgn (MIT), Copyright (c)
// 2022 Dominik Klein. The surrounding reader is a Dart implementation for
// Chessever's local Library scanner.
const _cbKingEnc = <int, _Delta>{
  0x49: _Delta(0, 1),
  0x39: _Delta(1, 1),
  0xD8: _Delta(1, 0),
  0x5D: _Delta(1, 7),
  0xC2: _Delta(0, 7),
  0xB1: _Delta(7, 7),
  0xB2: _Delta(7, 0),
  0x47: _Delta(7, 1),
  0x76: _Delta(2, 0),
  0xB5: _Delta(-2, 0),
};
const _cbQueen1Enc = <int, _Delta>{
  0xA5: _Delta(0, 1),
  0xB8: _Delta(0, 2),
  0xCB: _Delta(0, 3),
  0x53: _Delta(0, 4),
  0x7F: _Delta(0, 5),
  0x6B: _Delta(0, 6),
  0x8D: _Delta(0, 7),
  0x79: _Delta(1, 0),
  0xBE: _Delta(2, 0),
  0xEB: _Delta(3, 0),
  0x21: _Delta(4, 0),
  0x99: _Delta(5, 0),
  0xD2: _Delta(6, 0),
  0x57: _Delta(7, 0),
  0x4D: _Delta(1, 1),
  0xB4: _Delta(2, 2),
  0xBF: _Delta(3, 3),
  0x62: _Delta(4, 4),
  0xBD: _Delta(5, 5),
  0x24: _Delta(6, 6),
  0x96: _Delta(7, 7),
  0xA7: _Delta(1, 7),
  0x48: _Delta(2, 6),
  0x28: _Delta(3, 5),
  0x6E: _Delta(4, 4),
  0x2F: _Delta(5, 3),
  0x5A: _Delta(6, 2),
  0x18: _Delta(7, 1),
};
const _cbQueen2Enc = <int, _Delta>{
  0xE5: _Delta(0, 1),
  0x94: _Delta(0, 2),
  0x50: _Delta(0, 3),
  0x11: _Delta(0, 4),
  0xEA: _Delta(0, 5),
  0x31: _Delta(0, 6),
  0x01: _Delta(0, 7),
  0x5C: _Delta(1, 0),
  0x95: _Delta(2, 0),
  0xCA: _Delta(3, 0),
  0xD3: _Delta(4, 0),
  0x1D: _Delta(5, 0),
  0x7E: _Delta(6, 0),
  0xEF: _Delta(7, 0),
  0x44: _Delta(1, 1),
  0x80: _Delta(2, 2),
  0xA0: _Delta(3, 3),
  0x1F: _Delta(4, 4),
  0x83: _Delta(5, 5),
  0x00: _Delta(6, 6),
  0x4B: _Delta(7, 7),
  0x67: _Delta(1, 7),
  0x20: _Delta(2, 6),
  0x5B: _Delta(3, 5),
  0x2A: _Delta(4, 4),
  0x92: _Delta(5, 3),
  0xB6: _Delta(6, 2),
  0x60: _Delta(7, 1),
};
const _cbQueen3Enc = <int, _Delta>{
  0x1A: _Delta(0, 1),
  0x42: _Delta(0, 2),
  0x0F: _Delta(0, 3),
  0x0D: _Delta(0, 4),
  0xB0: _Delta(0, 5),
  0xD1: _Delta(0, 6),
  0x23: _Delta(0, 7),
  0xF0: _Delta(1, 0),
  0x7A: _Delta(2, 0),
  0x54: _Delta(3, 0),
  0x4F: _Delta(4, 0),
  0xF4: _Delta(5, 0),
  0xA8: _Delta(6, 0),
  0x72: _Delta(7, 0),
  0xE7: _Delta(1, 1),
  0x40: _Delta(2, 2),
  0x38: _Delta(3, 3),
  0x59: _Delta(4, 4),
  0x87: _Delta(5, 5),
  0xE8: _Delta(6, 6),
  0x6C: _Delta(7, 7),
  0x86: _Delta(1, 7),
  0x04: _Delta(2, 6),
  0xF1: _Delta(3, 5),
  0x8C: _Delta(4, 4),
  0xCE: _Delta(5, 3),
  0x6A: _Delta(6, 2),
  0xDB: _Delta(7, 1),
};
const _cbRook1Enc = <int, _Delta>{
  0x4E: _Delta(0, 1),
  0xF8: _Delta(0, 2),
  0x43: _Delta(0, 3),
  0xD7: _Delta(0, 4),
  0x63: _Delta(0, 5),
  0x9C: _Delta(0, 6),
  0xE6: _Delta(0, 7),
  0x2E: _Delta(1, 0),
  0xC6: _Delta(2, 0),
  0x26: _Delta(3, 0),
  0x88: _Delta(4, 0),
  0x30: _Delta(5, 0),
  0x61: _Delta(6, 0),
  0x6F: _Delta(7, 0),
};
const _cbRook2Enc = <int, _Delta>{
  0x14: _Delta(0, 1),
  0xA9: _Delta(0, 2),
  0x68: _Delta(0, 3),
  0xEE: _Delta(0, 4),
  0xFB: _Delta(0, 5),
  0x77: _Delta(0, 6),
  0xE2: _Delta(0, 7),
  0xA6: _Delta(1, 0),
  0x05: _Delta(2, 0),
  0x8B: _Delta(3, 0),
  0xA1: _Delta(4, 0),
  0x98: _Delta(5, 0),
  0x32: _Delta(6, 0),
  0x52: _Delta(7, 0),
};
const _cbRook3Enc = <int, _Delta>{
  0x81: _Delta(0, 1),
  0x82: _Delta(0, 2),
  0x9A: _Delta(0, 3),
  0x1B: _Delta(0, 4),
  0x9D: _Delta(0, 5),
  0x0A: _Delta(0, 6),
  0x2B: _Delta(0, 7),
  0x8F: _Delta(1, 0),
  0xCD: _Delta(2, 0),
  0xED: _Delta(3, 0),
  0x10: _Delta(4, 0),
  0x74: _Delta(5, 0),
  0x69: _Delta(6, 0),
  0xD6: _Delta(7, 0),
};
const _cbBishop1Enc = <int, _Delta>{
  0x02: _Delta(1, 1),
  0x97: _Delta(2, 2),
  0xE1: _Delta(3, 3),
  0x41: _Delta(4, 4),
  0xC3: _Delta(5, 5),
  0x7C: _Delta(6, 6),
  0xE4: _Delta(7, 7),
  0x06: _Delta(1, 7),
  0xB7: _Delta(2, 6),
  0x55: _Delta(3, 5),
  0xD9: _Delta(4, 4),
  0x2C: _Delta(5, 3),
  0xAE: _Delta(6, 2),
  0x37: _Delta(7, 1),
};
const _cbBishop2Enc = <int, _Delta>{
  0xF6: _Delta(1, 1),
  0x3F: _Delta(2, 2),
  0x08: _Delta(3, 3),
  0x93: _Delta(4, 4),
  0x73: _Delta(5, 5),
  0x5E: _Delta(6, 6),
  0x78: _Delta(7, 7),
  0x35: _Delta(1, 7),
  0xF2: _Delta(2, 6),
  0x6D: _Delta(3, 5),
  0x71: _Delta(4, 4),
  0xA2: _Delta(5, 3),
  0xF3: _Delta(6, 2),
  0x16: _Delta(7, 1),
};
const _cbBishop3Enc = <int, _Delta>{
  0x51: _Delta(1, 1),
  0xB9: _Delta(2, 2),
  0x45: _Delta(3, 3),
  0x3B: _Delta(4, 4),
  0x56: _Delta(5, 5),
  0x91: _Delta(6, 6),
  0xFD: _Delta(7, 7),
  0xAB: _Delta(1, 7),
  0x66: _Delta(2, 6),
  0x3E: _Delta(3, 5),
  0x46: _Delta(4, 4),
  0xB3: _Delta(5, 3),
  0xFC: _Delta(6, 2),
  0xC8: _Delta(7, 1),
};
const _cbKnight1Enc = <int, _Delta>{
  0x58: _Delta(2, 1),
  0x3D: _Delta(1, 2),
  0xFA: _Delta(-1, 2),
  0xE9: _Delta(-2, 1),
  0xBA: _Delta(-2, -1),
  0xD4: _Delta(-1, -2),
  0xDD: _Delta(1, -2),
  0x4A: _Delta(2, -1),
};
const _cbKnight2Enc = <int, _Delta>{
  0xC4: _Delta(2, 1),
  0x0E: _Delta(1, 2),
  0xFE: _Delta(-1, 2),
  0x5F: _Delta(-2, 1),
  0x75: _Delta(-2, -1),
  0x07: _Delta(-1, -2),
  0x89: _Delta(1, -2),
  0x34: _Delta(2, -1),
};
const _cbKnight3Enc = <int, _Delta>{
  0x9B: _Delta(2, 1),
  0xC0: _Delta(1, 2),
  0xE3: _Delta(-1, 2),
  0xA3: _Delta(-2, 1),
  0xAC: _Delta(-2, -1),
  0xC9: _Delta(-1, -2),
  0xEC: _Delta(1, -2),
  0x27: _Delta(2, -1),
};
const _cbPawnAEnc = <int, _Delta>{
  0x2D: _Delta(0, 1),
  0xC1: _Delta(0, 2),
  0x8E: _Delta(1, 1),
  0xF5: _Delta(-1, 1),
};
const _cbPawnBEnc = <int, _Delta>{
  0x64: _Delta(0, 1),
  0x17: _Delta(0, 2),
  0x70: _Delta(1, 1),
  0xA4: _Delta(-1, 1),
};
const _cbPawnCEnc = <int, _Delta>{
  0x7B: _Delta(0, 1),
  0xDA: _Delta(0, 2),
  0xE0: _Delta(1, 1),
  0x85: _Delta(-1, 1),
};
const _cbPawnDEnc = <int, _Delta>{
  0xC5: _Delta(0, 1),
  0x0B: _Delta(0, 2),
  0x90: _Delta(1, 1),
  0xF9: _Delta(-1, 1),
};
const _cbPawnEEnc = <int, _Delta>{
  0x84: _Delta(0, 1),
  0xFF: _Delta(0, 2),
  0x15: _Delta(1, 1),
  0x36: _Delta(-1, 1),
};
const _cbPawnFEnc = <int, _Delta>{
  0x09: _Delta(0, 1),
  0x9E: _Delta(0, 2),
  0x7D: _Delta(1, 1),
  0xDE: _Delta(-1, 1),
};
const _cbPawnGEnc = <int, _Delta>{
  0xBB: _Delta(0, 1),
  0xDF: _Delta(0, 2),
  0xBC: _Delta(1, 1),
  0x3A: _Delta(-1, 1),
};
const _cbPawnHEnc = <int, _Delta>{
  0x12: _Delta(0, 1),
  0x33: _Delta(0, 2),
  0x13: _Delta(1, 1),
  0x19: _Delta(-1, 1),
};
const _deobfuscate2b = <int>[
  0xA2,
  0x95,
  0x43,
  0xF5,
  0xC1,
  0x3D,
  0x4A,
  0x6C,
  0x53,
  0x83,
  0xCC,
  0x7C,
  0xFF,
  0xAE,
  0x68,
  0xAD,
  0xD1,
  0x92,
  0x8B,
  0x8D,
  0x35,
  0x81,
  0x5E,
  0x74,
  0x26,
  0x8E,
  0xAB,
  0xCA,
  0xFD,
  0x9A,
  0xF3,
  0xA0,
  0xA5,
  0x15,
  0xFC,
  0xB1,
  0x1E,
  0xED,
  0x30,
  0xEA,
  0x22,
  0xEB,
  0xA7,
  0xCD,
  0x4E,
  0x6F,
  0x2E,
  0x24,
  0x32,
  0x94,
  0x41,
  0x8C,
  0x6E,
  0x58,
  0x82,
  0x50,
  0xBB,
  0x02,
  0x8A,
  0xD8,
  0xFA,
  0x60,
  0xDE,
  0x52,
  0xBA,
  0x46,
  0xAC,
  0x29,
  0x9D,
  0xD7,
  0xDF,
  0x08,
  0x21,
  0x01,
  0x66,
  0xA3,
  0xF1,
  0x19,
  0x27,
  0xB5,
  0x91,
  0xD5,
  0x42,
  0x0E,
  0xB4,
  0x4C,
  0xD9,
  0x18,
  0x5F,
  0xBC,
  0x25,
  0xA6,
  0x96,
  0x04,
  0x56,
  0x6A,
  0xAA,
  0x33,
  0x1C,
  0x2B,
  0x73,
  0xF0,
  0xDD,
  0xA4,
  0x37,
  0xD3,
  0xC5,
  0x10,
  0xBF,
  0x5A,
  0x23,
  0x34,
  0x75,
  0x5B,
  0xB8,
  0x55,
  0xD2,
  0x6B,
  0x09,
  0x3A,
  0x57,
  0x12,
  0xB3,
  0x77,
  0x48,
  0x85,
  0x9B,
  0x0F,
  0x9E,
  0xC7,
  0xC8,
  0xA1,
  0x7F,
  0x7A,
  0xC0,
  0xBD,
  0x31,
  0x6D,
  0xF6,
  0x3E,
  0xC3,
  0x11,
  0x71,
  0xCE,
  0x7D,
  0xDA,
  0xA8,
  0x54,
  0x90,
  0x97,
  0x1F,
  0x44,
  0x40,
  0x16,
  0xC9,
  0xE3,
  0x2C,
  0xCB,
  0x84,
  0xEC,
  0x9F,
  0x3F,
  0x5C,
  0xE6,
  0x76,
  0x0B,
  0x3C,
  0x20,
  0xB7,
  0x36,
  0x00,
  0xDC,
  0xE7,
  0xF9,
  0x4F,
  0xF7,
  0xAF,
  0x06,
  0x07,
  0xE0,
  0x1A,
  0x0A,
  0xA9,
  0x4B,
  0x0C,
  0xD6,
  0x63,
  0x87,
  0x89,
  0x1D,
  0x13,
  0x1B,
  0xE4,
  0x70,
  0x05,
  0x47,
  0x67,
  0x7B,
  0x2F,
  0xEE,
  0xE2,
  0xE8,
  0x98,
  0x0D,
  0xEF,
  0xCF,
  0xC4,
  0xF4,
  0xFB,
  0xB0,
  0x17,
  0x99,
  0x64,
  0xF2,
  0xD4,
  0x2A,
  0x03,
  0x4D,
  0x78,
  0xC6,
  0xFE,
  0x65,
  0x86,
  0x88,
  0x79,
  0x45,
  0x3B,
  0xE5,
  0x49,
  0x8F,
  0x2D,
  0xB9,
  0xBE,
  0x62,
  0x93,
  0x14,
  0xE9,
  0xD0,
  0x38,
  0x9C,
  0xB2,
  0xC2,
  0x59,
  0x5D,
  0xB6,
  0x72,
  0x51,
  0xF8,
  0x28,
  0x7E,
  0x61,
  0x39,
  0xE1,
  0xDB,
  0x69,
  0x80,
];
