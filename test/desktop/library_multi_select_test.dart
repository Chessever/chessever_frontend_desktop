import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/utils/library_multi_select.dart';

void main() {
  test('range selects inclusively in either direction', () {
    final rows = ['a', 'b', 'c', 'd'];
    expect(LibraryMultiSelect.range(rowIds: rows, from: 1, to: 3), {
      'b',
      'c',
      'd',
    });
    expect(LibraryMultiSelect.range(rowIds: rows, from: 3, to: 1), {
      'b',
      'c',
      'd',
    });
  });

  test('range clamps to visible row ids', () {
    final rows = ['a', 'b'];
    expect(LibraryMultiSelect.range(rowIds: rows, from: -10, to: 50), {
      'a',
      'b',
    });
  });

  test('clampToRows drops selections that are no longer visible', () {
    expect(LibraryMultiSelect.clampToRows({'a', 'x', 'c'}, ['a', 'b', 'c']), {
      'a',
      'c',
    });
  });

  test('nextAnchor moves by one row and clamps at list edges', () {
    final rows = ['a', 'b', 'c'];
    expect(
      LibraryMultiSelect.nextAnchor(rowIds: rows, anchor: null, delta: 1),
      1,
    );
    expect(LibraryMultiSelect.nextAnchor(rowIds: rows, anchor: 1, delta: 1), 2);
    expect(LibraryMultiSelect.nextAnchor(rowIds: rows, anchor: 2, delta: 1), 2);
    expect(
      LibraryMultiSelect.nextAnchor(rowIds: rows, anchor: 0, delta: -1),
      0,
    );
  });

  test('nextExtent advances the moving end of a range selection', () {
    final rows = ['a', 'b', 'c', 'd'];
    var extent = LibraryMultiSelect.nextExtent(
      rowIds: rows,
      extent: 1,
      delta: 1,
    );
    expect(extent, 2);
    expect(LibraryMultiSelect.range(rowIds: rows, from: 1, to: extent!), {
      'b',
      'c',
    });

    extent = LibraryMultiSelect.nextExtent(
      rowIds: rows,
      extent: extent,
      delta: 1,
    );
    expect(extent, 3);
    expect(LibraryMultiSelect.range(rowIds: rows, from: 1, to: extent!), {
      'b',
      'c',
      'd',
    });
  });
}
