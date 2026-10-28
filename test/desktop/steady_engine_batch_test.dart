import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/engine/complete_pv_batch.dart';

void main() {
  test('publishes all ranks atomically with their real depth', () {
    final batch = CompletePvBatch<String>(3);
    expect(batch.add(rank: 1, depth: 8, value: 'a'), isNull);
    expect(batch.add(rank: 3, depth: 8, value: 'c'), isNull);
    expect(batch.add(rank: 2, depth: 8, value: 'b'), ['a', 'b', 'c']);
    expect(batch.depth, 8);
    expect(batch.add(rank: 1, depth: 9, value: 'new a'), isNull);
    expect(batch.lines, ['a', 'b', 'c']);
    expect(batch.depth, 8);
    expect(batch.add(rank: 2, depth: 9, value: 'new b'), isNull);
    expect(batch.add(rank: 3, depth: 9, value: 'new c'), [
      'new a',
      'new b',
      'new c',
    ]);
    expect(batch.depth, 9);
    expect(batch.add(rank: 1, depth: 8, value: 'late'), isNull);
    expect(batch.lines.first, 'new a');
  });
  test('a new request cannot inherit ranks from an earlier search', () {
    final old = CompletePvBatch<String>(2);
    old.add(rank: 1, depth: 10, value: 'old');
    final current = CompletePvBatch<String>(2);
    expect(current.add(rank: 2, depth: 10, value: 'current'), isNull);
    expect(current.lines, isEmpty);
    expect(current.add(rank: 0, depth: 10, value: 'invalid'), isNull);
    expect(current.add(rank: 3, depth: 10, value: 'invalid'), isNull);
  });
}
