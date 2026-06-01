import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/utils/mainline_annotation_index.dart';

void main() {
  group('mainlineAnnotationIndexForPointer', () {
    test('uses zero-based mainline half-move indexes', () {
      expect(mainlineAnnotationIndexForPointer(const [0]), 0);
      expect(mainlineAnnotationIndexForPointer(const [1]), 1);
      expect(mainlineAnnotationIndexForPointer(const [12]), 12);
    });

    test('ignores initial position and variation pointers', () {
      expect(mainlineAnnotationIndexForPointer(const []), isNull);
      expect(mainlineAnnotationIndexForPointer(const [2, 0, 0]), isNull);
    });
  });
}
