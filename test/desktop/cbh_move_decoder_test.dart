import 'dart:typed_data';

import 'package:chessever/desktop/services/cbh_frame_reader.dart';
import 'package:chessever/desktop/services/cbh_move_decoder.dart';
import 'package:chessever/desktop/services/cbh_move_tables.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes alternating ordinary pawn moves in Dart', () {
    final e4 = cbhMoveLookup.indexOf(0x80);
    final e5 = (cbhMoveLookup.indexOf(0x80) + 1) & 255;
    final frame = CbhGameFrame(
      raw: Uint8List(0),
      chess960: false,
      startingPosition: null,
      moveBytes: Uint8List.fromList([e4, e5]),
    );

    expect(CbhMoveDecoder().decode(frame), ['e4', 'e5']);
  });
}
