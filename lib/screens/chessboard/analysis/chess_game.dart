import 'package:chessever/screens/chessboard/utils/chessever_classification_header.dart';
import 'package:chessever/utils/pgn_clock_utils.dart';
import 'package:dartchess/dartchess.dart';

typedef Number = int;

typedef ChessLine = List<ChessMove>;

final RegExp _evalRegex = RegExp(r'\[%eval ([^\]]+)\]');

/// The address of the first move of a game: the walk the private
/// `[ChessEverClassification "…"]` header tag is built from starts at ply 1.
const String kChesseverFirstMainlineMoveKey = '1';

/// Move NAGs as a parsed PGN node delivers them, with ChessEver's private
/// classification restored into the native `$240`–`$247` block.
///
/// This is the single import-side hook that makes the external-compatible copy
/// lossless: a game copied out for chess.com (standard NAGs only, exact class
/// in the header tag) comes back into the app with the same
/// Brilliant/Book/Missed-win classification it left with. A PGN that already
/// carries the native block is returned untouched, so nothing is ever annotated
/// twice — see [restoreChesseverClassificationNags].
///
/// [key] is this move's address in the movetext ([chesseverMoveKey]) and
/// [headerCodes] the tag the copy wrote, so a restored class lands on the move
/// it belonged to even inside a variation.
///
/// Pair it with [importedMoveComments] so a legacy consumed `[%ce …]` marker
/// does not ride along into the game (and into the files it is saved to).
List<int>? restoredMoveNags(
  List<int>? nags,
  PgnNodeData data, {
  String? key,
  Map<String, int>? headerCodes,
}) => restoreChesseverClassificationNags(
  nags: nags,
  comments: <String>[...?data.startingComments, ...?data.comments],
  moveKey: key,
  headerCodes: headerCodes,
);

/// A parsed PGN node's comments, minus any legacy `[%ce …]` marker whose codes
/// were folded into the move's NAGs by [restoredMoveNags].
///
/// Prose, clocks and `[%eval …]` payloads are untouched, and a marker whose
/// codes are unknown is preserved: nothing was restored, so nothing is dropped.
List<String>? importedMoveComments(
  List<String>? startingComments,
  List<String>? comments,
) {
  final combined = <String>[...?startingComments, ...?comments];
  if (combined.isEmpty) return null;
  final stripped = stripChesseverMarker(combined);
  return (stripped?.isEmpty ?? true) ? null : stripped;
}

class ChessGame {
  static const String metadataIsLiveKey = 'isLiveGame';
  static const String metadataAllowMainlineExtensionKey =
      'allowMainlineExtension';
  static const String metadataGameEndingPlyIndexKey = 'gameEndingPlyIndex';

  final String gameId;
  final String startingFen;
  final Map<String, dynamic> metadata;
  final ChessLine mainline;

  /// Analysis displaced by an authoritative takeback to the root position.
  ///
  /// A move tree normally hangs variations from a move, so an empty mainline
  /// has no node that can retain the previous tree. Keep those lines detached
  /// until a later live move provides an anchor. This field is serialized with
  /// the rest of the game so a session/save round trip cannot discard them.
  final List<ChessLine>? detachedRootAnalysis;

  ChessGame({
    required this.gameId,
    required this.startingFen,
    required this.metadata,
    required this.mainline,
    this.detachedRootAnalysis,
  });

  factory ChessGame.fromJson(Map<String, dynamic> json) {
    return ChessGame(
      gameId: json['id'] as String,
      startingFen: json['sf'] as String,
      metadata: (json['md'] as Map).cast<String, dynamic>(),
      mainline:
          (json['m'] as List)
              .map(
                (move) =>
                    ChessMove.fromJson((move as Map).cast<String, dynamic>()),
              )
              .toList(),
      detachedRootAnalysis:
          json['dra'] == null
              ? null
              : (json['dra'] as List)
                  .map(
                    (line) =>
                        (line as List)
                            .map(
                              (move) => ChessMove.fromJson(
                                (move as Map).cast<String, dynamic>(),
                              ),
                            )
                            .toList(),
                  )
                  .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': gameId,
    'sf': startingFen,
    'md': metadata,
    'm': mainline.map((move) => move.toJson()).toList(),
    if (detachedRootAnalysis != null)
      'dra':
          detachedRootAnalysis!
              .map((line) => line.map((move) => move.toJson()).toList())
              .toList(),
  };

  ChessGame copyWith({
    String? gameId,
    String? startingFen,
    Map<String, dynamic>? metadata,
    ChessLine? mainline,
    List<ChessLine>? detachedRootAnalysis,
    bool overrideDetachedRootAnalysis = false,
  }) {
    return ChessGame(
      gameId: gameId ?? this.gameId,
      startingFen: startingFen ?? this.startingFen,
      metadata: metadata ?? this.metadata,
      mainline: mainline ?? this.mainline,
      detachedRootAnalysis:
          overrideDetachedRootAnalysis
              ? detachedRootAnalysis
              : this.detachedRootAnalysis,
    );
  }

  bool get isLiveGame {
    final flag = metadata[metadataIsLiveKey];
    if (flag is bool) return flag;
    if (flag is String) {
      return flag.toLowerCase() == 'true';
    }
    return false;
  }

  bool get allowMainlineExtension {
    if (isLiveGame) return false;
    return metadata[metadataAllowMainlineExtensionKey] != false;
  }

  bool get hasDecidedResult {
    final result = (metadata['Result']?.toString() ?? '')
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('½', '1/2');
    return result == '1-0' ||
        result == '1.0-0.0' ||
        result == '1-0.0' ||
        result == '0-1' ||
        result == '0.0-1.0' ||
        result == '0.0-1' ||
        result == '1/2-1/2' ||
        result == '0.5-0.5' ||
        result == '1.0-1.0';
  }

  int? get gameEndingPlyIndex {
    if (!hasDecidedResult || mainline.isEmpty) return null;
    final stored = metadata[metadataGameEndingPlyIndexKey];
    final parsed =
        stored is int ? stored : int.tryParse(stored?.toString() ?? '');
    if (parsed != null && parsed >= 0 && parsed < mainline.length) {
      return parsed;
    }
    return mainline.length - 1;
  }

  ChessGame rememberGameEndingPlyIndex(int plyIndex) {
    if (!hasDecidedResult || plyIndex < 0 || plyIndex >= mainline.length) {
      return this;
    }
    if (gameEndingPlyIndex == plyIndex &&
        metadata.containsKey(metadataGameEndingPlyIndexKey)) {
      return this;
    }
    return copyWith(
      metadata: <String, dynamic>{
        ...metadata,
        metadataGameEndingPlyIndexKey: plyIndex,
      },
    );
  }

  String? get timeControl => metadata['TimeControl'] as String?;

  factory ChessGame.fromPgn(String gameId, String pgn) {
    final pgnGame = PgnGame.parsePgn(pgn);
    final startingPosition = PgnGame.startingPosition(pgnGame.headers);
    // The classes a copy carries out-of-band. Read before the headers become
    // metadata, so the private carrier can never ride into the game — or into
    // the user's files, which keep the native block.
    final headerCodes = parseChesseverClassificationHeader(
      chesseverClassificationHeaderOf(pgnGame.headers),
    );

    final mainline = _parsePgnNodes(
      pgnGame.moves.children,
      startingPosition,
      headerCodes,
    );
    if (mainline.isNotEmpty && pgnGame.comments.isNotEmpty) {
      mainline[0] = mainline[0].copyWith(
        comments: [...pgnGame.comments, ...?mainline[0].comments],
      );
    }

    return ChessGame(
      gameId: gameId,
      startingFen: startingPosition.fen,
      metadata: withoutChesseverClassificationHeader(pgnGame.headers),
      mainline: mainline,
    );
  }

  static List<ChessMove> _parsePgnNodes(
    List<PgnNode> siblings,
    Position position,
    Map<String, int> headerCodes,
  ) {
    if (siblings.isEmpty) return const [];

    final mainlineNode = siblings.first;
    if (mainlineNode is! PgnChildNode) return const [];

    final line = _parsePgnLineFromChild(
      mainlineNode,
      position,
      key: kChesseverFirstMainlineMoveKey,
      headerCodes: headerCodes,
    );
    if (line.isEmpty) return line;
    // Root siblings are alternatives to the first move, not continuations
    // after it. The model represents these as same-turn RAVs on that move.
    final rootVariations = <ChessLine>[];
    var alternative = 0;
    for (final sibling in siblings.skip(1)) {
      if (sibling is! PgnChildNode<PgnNodeData>) continue;
      alternative++;
      rootVariations.add(
        _parsePgnLineFromChild(
          sibling,
          position,
          key: chesseverMoveKey(
            parentKey: kChesseverFirstMainlineMoveKey,
            variation: alternative,
            index: 1,
          ),
          headerCodes: headerCodes,
        ),
      );
    }
    final usableVariations = rootVariations
        .where((variation) => variation.isNotEmpty)
        .toList();
    if (usableVariations.isNotEmpty) {
      line[0] = line[0].copyWith(
        variations: [...usableVariations, ...?line[0].variations],
        overrideVariations: true,
      );
    }
    return line;
  }

  static List<ChessMove> _parsePgnLineFromChild(
    PgnChildNode<PgnNodeData> node,
    Position position, {
    required String? key,
    required Map<String, int> headerCodes,
  }) {
    final data = node.data;
    final move = position.parseSan(data.san);
    if (move == null) return const [];

    final nextPosition = position.play(move);
    final continuationKey = key == null ? null : chesseverNextMoveKey(key);

    final variations = <ChessLine>[];
    if (node.children.length > 1) {
      // Siblings of the continuation move are written *after* it: each block is
      // an alternative to that move, so the block's moves are addressed from
      // the continuation move's own key.
      var alternative = 0;
      for (final variationNode in node.children.skip(1)) {
        alternative++;
        variations.add(
          _parsePgnLineFromChild(
            variationNode,
            nextPosition,
            key: continuationKey == null
                ? null
                : chesseverMoveKey(
                    parentKey: continuationKey,
                    variation: alternative,
                    index: 1,
                  ),
            headerCodes: headerCodes,
          ),
        );
      }
    }

    String? clockTime;
    String? eval;
    if (data.comments != null) {
      for (final comment in data.comments!) {
        final parsedClock = extractPgnClockStringFromComment(comment);
        if (parsedClock != null) {
          clockTime = parsedClock;
        }
        final evalMatch = _evalRegex.firstMatch(comment);
        if (evalMatch != null) {
          eval = evalMatch.group(1);
        }
      }
    }

    final currentMove = ChessMove(
      num: position.fullmoves,
      fen: nextPosition.fen,
      san: data.san,
      uci: move.uci,
      turn: position.turn == Side.black ? ChessColor.black : ChessColor.white,
      clockTime: clockTime,
      eval: eval,
      comments: importedMoveComments(data.startingComments, data.comments),
      nags: restoredMoveNags(
        data.nags,
        data,
        key: key,
        headerCodes: headerCodes,
      ),
      variations: variations.isNotEmpty ? variations : null,
    );

    final line = <ChessMove>[currentMove];
    if (node.children.isNotEmpty) {
      line.addAll(
        _parsePgnLineFromChild(
          node.children.first,
          nextPosition,
          key: continuationKey,
          headerCodes: headerCodes,
        ),
      );
    }

    return line;
  }
}

enum ChessColor {
  black('black'),
  white('white');

  final String value;

  const ChessColor(this.value);

  factory ChessColor.fromJson(String value) {
    return ChessColor.values.firstWhere(
      (color) => color.value == value,
      orElse: () => throw ArgumentError('Invalid ChessColor value: $value'),
    );
  }

  String toJson() => value;
}

class ChessMove {
  final Number num;
  final String fen;
  final String san;
  final String uci;
  final ChessColor turn;
  final String? clockTime;
  final String? eval;
  final List<String>? comments;
  final List<int>? nags;
  final List<ChessLine>? variations;

  ChessMove({
    required this.num,
    required this.fen,
    required this.san,
    required this.uci,
    required this.turn,
    this.clockTime,
    this.eval,
    this.comments,
    this.nags,
    this.variations,
  });

  factory ChessMove.fromJson(Map<String, dynamic> json) {
    return ChessMove(
      num: json['n'] as Number,
      fen: json['f'] as String,
      san: json['s'] as String,
      uci: json['u'] as String,
      turn: ChessColor.fromJson(json['t'] as String),
      clockTime: json['ct'] as String?,
      eval: json['e'] as String?,
      comments: (json['c'] as List?)?.cast<String>(),
      nags: (json['g'] as List?)?.cast<int>(),
      variations:
          json['v'] == null
              ? null
              : (json['v'] as List)
                  .map(
                    (variation) =>
                        (variation as List)
                            .map(
                              (move) => ChessMove.fromJson(
                                (move as Map).cast<String, dynamic>(),
                              ),
                            )
                            .toList(),
                  )
                  .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'n': num,
    'f': fen,
    's': san,
    'u': uci,
    't': turn.toJson(),
    'ct': clockTime,
    'e': eval,
    if (comments != null) 'c': comments,
    if (nags != null) 'g': nags,
    if (variations != null)
      'v':
          variations!
              .map(
                (variation) => variation.map((move) => move.toJson()).toList(),
              )
              .toList(),
  };

  ChessMove copyWith({
    Number? num,
    String? fen,
    String? san,
    String? uci,
    ChessColor? turn,
    String? clockTime,
    String? eval,
    List<String>? comments,
    List<int>? nags,
    List<ChessLine>? variations,
    bool overrideVariations = false,
  }) {
    return ChessMove(
      num: num ?? this.num,
      fen: fen ?? this.fen,
      san: san ?? this.san,
      uci: uci ?? this.uci,
      turn: turn ?? this.turn,
      clockTime: clockTime ?? this.clockTime,
      eval: eval ?? this.eval,
      comments: comments ?? this.comments,
      nags: nags ?? this.nags,
      variations: overrideVariations ? variations : this.variations,
    );
  }
}
