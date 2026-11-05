import 'package:chessground/chessground.dart';
import 'package:chessground/src/widgets/animation.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pawn = Piece(color: Side.white, role: Role.pawn);

  test(
    'reverse navigation starts from the moving piece, not its destination',
    () {
      final old = <Square, Piece>{Square.e4: pawn};
      final next = <Square, Piece>{Square.e2: pawn};
      final (translations, _) = preparePieceAnimations(old, next);
      final origins = retargetPieceAnimations(
        previous: {Square.e4: (piece: pawn, from: Square.e2)},
        previousOrigins: const {},
        progress: 0.5,
        next: translations,
        newPosition: next,
      );
      expect(origins[Square.e2], const Offset(4, 2)); // e3
    },
  );

  test('an opponent move carries an unfinished translation forward', () {
    const blackPawn = Piece(color: Side.black, role: Role.pawn);
    final old = <Square, Piece>{Square.e4: pawn, Square.e7: blackPawn};
    final next = <Square, Piece>{Square.e4: pawn, Square.e5: blackPawn};
    final (translations, _) = preparePieceAnimations(old, next);
    final origins = retargetPieceAnimations(
      previous: {Square.e4: (piece: pawn, from: Square.e2)},
      previousOrigins: const {},
      progress: 0.5,
      next: translations,
      newPosition: next,
    );
    expect(translations.keys, containsAll([Square.e4, Square.e5]));
    expect(origins[Square.e4], const Offset(4, 2));
    expect(origins.containsKey(Square.e5), isFalse);
  });

  test(
    'repeated interruptions interpolate from the previous fractional origin',
    () {
      final translations = <Square, ({Piece piece, Square from})>{
        Square.e4: (piece: pawn, from: Square.e2),
      };
      final origins = retargetPieceAnimations(
        previous: {Square.e2: (piece: pawn, from: Square.e4)},
        previousOrigins: {Square.e2: const Offset(4, 2)},
        progress: 0.5,
        next: translations,
        newPosition: {Square.e4: pawn},
      );
      expect(origins[Square.e4], const Offset(4, 1.5));
    },
  );

  test('a completed animation or dropped piece is not resurrected', () {
    for (final complete in [false, true]) {
      final translations = <Square, ({Piece piece, Square from})>{};
      retargetPieceAnimations(
        previous: {Square.e4: (piece: pawn, from: Square.e2)},
        previousOrigins: const {},
        progress: complete ? 1 : 0.5,
        next: translations,
        newPosition: {Square.e4: pawn},
        lastDrop:
            complete ? null : const NormalMove(from: Square.e2, to: Square.e4),
      );
      expect(translations, isEmpty);
    }
  });

  test('one piece origin is never assigned to two destination pieces', () {
    final (translations, _) = preparePieceAnimations(
      readFen('8/8/8/8/8/8/PP6/8'),
      readFen('8/8/8/8/8/PP6/8/8'),
    );
    expect(
      translations.values.map((value) => value.from).toSet(),
      hasLength(2),
    );
  });
}
