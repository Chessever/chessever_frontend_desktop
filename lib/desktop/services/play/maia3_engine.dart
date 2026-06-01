import 'dart:math';
import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Local Maia 3 ONNX runner.
///
/// Maia 3 is not a UCI engine. The current public model is an ONNX policy/value
/// network used by maiachess.com; this adapter gives the Play pane the same
/// local, offline move generation path as the web worker.
class Maia3LocalEngine {
  Maia3LocalEngine._(this._session);

  final OrtSession _session;
  final Random _random = Random();

  static Future<Maia3LocalEngine> load(String modelPath) async {
    final runtime = OnnxRuntime();
    final session = await runtime.createSession(
      modelPath,
      options: OrtSessionOptions(intraOpNumThreads: 1, interOpNumThreads: 1),
    );
    return Maia3LocalEngine._(session);
  }

  Future<void> dispose() => _session.close();

  Future<String?> pickMove({
    required String fen,
    required int eloSelf,
    required int eloOpponent,
    bool sample = true,
  }) async {
    final mirrored = _isBlackToMove(fen);
    final modelFen = mirrored ? _mirrorFen(fen) : fen;
    final position = Position.setupPosition(
      Rule.chess,
      Setup.parseFen(modelFen),
    );
    final legalIndices = _legalMoveIndices(position);
    if (legalIndices.isEmpty) return null;

    final inputs = <String, OrtValue>{
      'tokens': await OrtValue.fromList(_boardTokens(modelFen), [1, 64, 12]),
      'elo_self': await OrtValue.fromList(
        Float32List.fromList([_clampMaiaElo(eloSelf)]),
        [1],
      ),
      'elo_oppo': await OrtValue.fromList(
        Float32List.fromList([_clampMaiaElo(eloOpponent)]),
        [1],
      ),
    };
    Map<String, OrtValue>? outputs;
    try {
      outputs = await _session.run(inputs);
      final logits = await outputs['logits_move']!.asFlattenedList();
      final chosen = _chooseMoveIndex(logits, legalIndices, sample: sample);
      final modelMove = _moveFromMaia3Index(chosen);
      return mirrored ? _mirrorMove(modelMove) : modelMove;
    } finally {
      for (final input in inputs.values) {
        await input.dispose();
      }
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    }
  }

  int _chooseMoveIndex(
    List<dynamic> logits,
    List<int> legalIndices, {
    required bool sample,
  }) {
    if (!sample || legalIndices.length == 1) {
      return legalIndices.reduce(
        (best, idx) =>
            (logits[idx] as num) > (logits[best] as num) ? idx : best,
      );
    }

    var maxLogit = double.negativeInfinity;
    for (final idx in legalIndices) {
      final value = (logits[idx] as num).toDouble();
      if (value > maxLogit) maxLogit = value;
    }

    var total = 0.0;
    final weights = <double>[];
    for (final idx in legalIndices) {
      final weight = exp((logits[idx] as num).toDouble() - maxLogit);
      weights.add(weight);
      total += weight;
    }
    var roll = _random.nextDouble() * total;
    for (var i = 0; i < legalIndices.length; i++) {
      roll -= weights[i];
      if (roll <= 0) return legalIndices[i];
    }
    return legalIndices.last;
  }
}

bool _isBlackToMove(String fen) => fen.split(RegExp(r'\s+'))[1] == 'b';

double _clampMaiaElo(int elo) => elo.clamp(600, 2600).toDouble();

Float32List _boardTokens(String fen) {
  final placement = fen.split(RegExp(r'\s+')).first;
  final rows = placement.split('/');
  const pieces = <String>[
    'P',
    'N',
    'B',
    'R',
    'Q',
    'K',
    'p',
    'n',
    'b',
    'r',
    'q',
    'k',
  ];
  final out = Float32List(64 * 12);
  for (var rank = 0; rank < 8; rank++) {
    final row = 7 - rank;
    var file = 0;
    for (final codeUnit in rows[rank].codeUnits) {
      final char = String.fromCharCode(codeUnit);
      final empty = int.tryParse(char);
      if (empty != null) {
        file += empty;
        continue;
      }
      final piece = pieces.indexOf(char);
      if (piece >= 0) {
        final square = row * 8 + file;
        out[square * 12 + piece] = 1.0;
      }
      file += 1;
    }
  }
  return out;
}

List<int> _legalMoveIndices(Position position) {
  final out = <int>[];
  final legalMoves = makeLegalMoves(
    position,
    includeAlternateCastlingMoves: false,
  );
  for (final entry in legalMoves.entries) {
    final from = entry.key;
    final piece = position.board.pieceAt(from);
    if (piece == null) continue;
    for (final to in entry.value) {
      if (piece.role == Role.pawn && to.rank == Rank.eighth) {
        for (final promotion in const <Role>[
          Role.queen,
          Role.rook,
          Role.bishop,
          Role.knight,
        ]) {
          out.add(_maia3MoveIndex(from, to, promotion));
        }
      } else {
        out.add(_maia3MoveIndex(from, to, null));
      }
    }
  }
  return out;
}

int _maia3MoveIndex(Square from, Square to, Role? promotion) {
  if (promotion == null) return from * 64 + to;
  final promo = switch (promotion) {
    Role.queen => 0,
    Role.rook => 1,
    Role.bishop => 2,
    Role.knight => 3,
    _ => 0,
  };
  return 4096 + (((from.file * 8) + to.file) * 4) + promo;
}

String _moveFromMaia3Index(int index) {
  if (index < 4096) {
    final from = Square(index ~/ 64);
    final to = Square(index % 64);
    return from.name + to.name;
  }
  final offset = index - 4096;
  final pair = offset ~/ 4;
  final from = Square.fromCoords(File(pair ~/ 8), Rank.seventh);
  final to = Square.fromCoords(File(pair % 8), Rank.eighth);
  final promotion = switch (offset % 4) {
    0 => 'q',
    1 => 'r',
    2 => 'b',
    _ => 'n',
  };
  return from.name + to.name + promotion;
}

String _mirrorMove(String move) {
  final promotion = move.length > 4 ? move.substring(4) : '';
  return _mirrorSquare(move.substring(0, 2)) +
      _mirrorSquare(move.substring(2, 4)) +
      promotion;
}

String _mirrorSquare(String square) {
  final file = square[0];
  final rank = 9 - int.parse(square[1]);
  return '$file$rank';
}

String _mirrorFen(String fen) {
  final parts = fen.split(RegExp(r'\s+'));
  final ranks = parts[0]
      .split('/')
      .reversed
      .map(
        (rank) => String.fromCharCodes(
          rank.codeUnits.map((unit) {
            final char = String.fromCharCode(unit);
            if (char.toUpperCase() == char && char.toLowerCase() != char) {
              return char.toLowerCase().codeUnitAt(0);
            }
            if (char.toLowerCase() == char && char.toUpperCase() != char) {
              return char.toUpperCase().codeUnitAt(0);
            }
            return unit;
          }),
        ),
      )
      .join('/');
  final active = parts[1] == 'w' ? 'b' : 'w';
  final castling = _mirrorCastling(parts[2]);
  final ep = parts[3] == '-' ? '-' : _mirrorSquare(parts[3]);
  return '$ranks $active $castling $ep ${parts[4]} ${parts[5]}';
}

String _mirrorCastling(String castling) {
  if (castling == '-') return '-';
  final rights = castling.split('').toSet();
  final out = StringBuffer();
  if (rights.contains('k')) out.write('K');
  if (rights.contains('q')) out.write('Q');
  if (rights.contains('K')) out.write('k');
  if (rights.contains('Q')) out.write('q');
  final value = out.toString();
  return value.isEmpty ? '-' : value;
}
