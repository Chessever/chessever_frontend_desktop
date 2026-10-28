import 'package:chessever/desktop/services/library_book_failure_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a refused game is named with its reason', () {
    expect(
      libraryBookSnapshotFailureMessage({
        'code': 'invalid_collection_games',
        'games': [
          {
            'label': 'Steinitz - Von Bardeleben',
            'reason': 'Illegal move "Rxh7+" at 25...',
          },
        ],
      }, 422),
      'Could not prepare Steinitz - Von Bardeleben: Illegal move "Rxh7+" at 25... Your existing collection is unchanged.',
    );
  });

  test('an unclassified 400 or 422 is never called an empty folder', () {
    for (final status in [400, 422]) {
      final fallback = libraryBookSnapshotFailureMessage(null, status);
      expect(fallback, isNotNull);
      expect(fallback, isNot(contains('at least one game')));
    }
  });

  test('named and unrelated failures keep their own copy', () {
    expect(
      libraryBookSnapshotFailureMessage({'code': 'empty_collection'}, 422),
      isNull,
    );
    expect(
      libraryBookSnapshotFailureMessage({'code': 'forbidden_field'}, 422),
      isNull,
    );
    expect(libraryBookSnapshotFailureMessage(null, 503), isNull);
  });

  test('malformed or oversized details fall back to a plain sentence', () {
    expect(
      libraryBookSnapshotFailureMessage({
        'code': 'invalid_collection_games',
        'games': 'bad',
      }, 422),
      startsWith('One or more games'),
    );
    expect(
      libraryBookSnapshotFailureMessage({
        'code': 'invalid_collection_games',
        'games': [
          {'label': 'x' * 1000, 'reason': 'bad'},
        ],
      }, 422),
      startsWith('One or more games'),
    );
  });
}
