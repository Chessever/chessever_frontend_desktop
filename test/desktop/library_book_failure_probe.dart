// Pure-Dart transport-copy regression: no Flutter test runner required.
import 'dart:io';
import 'package:chessever/desktop/services/library_book_failure_message.dart';

void check(bool passed, String label) {
  if (!passed) throw StateError(label);
}

void main() {
  final message = libraryBookSnapshotFailureMessage({
    'code': 'invalid_collection_games',
    'games': [
      {
        'label': 'Steinitz - Von Bardeleben',
        'reason': 'Illegal move "Rxh7+" at 25...',
      },
    ],
  }, 422);
  check(
    message ==
        'Could not prepare Steinitz - Von Bardeleben: Illegal move "Rxh7+" at 25... Your existing collection is unchanged.',
    'structured failing game',
  );
  for (final code in [400, 422]) {
    final fallback = libraryBookSnapshotFailureMessage(null, code);
    check(
      fallback != null && !fallback.contains('at least one game'),
      'generic validation is not empty',
    );
  }
  check(
    libraryBookSnapshotFailureMessage({'code': 'empty_collection'}, 422) ==
        null,
    'preserve named empty collection mapping',
  );
  check(
    libraryBookSnapshotFailureMessage(null, 503) == null,
    'preserve other HTTP mappings',
  );
  check(
    libraryBookSnapshotFailureMessage({
      'code': 'invalid_collection_games',
      'games': 'bad',
    }, 422)!.startsWith('One or more games'),
    'malformed details safe fallback',
  );
  check(
    libraryBookSnapshotFailureMessage({
      'code': 'invalid_collection_games',
      'games': [
        {'label': 'x' * 1000, 'reason': 'bad'},
      ],
    }, 422)!.startsWith('One or more games'),
    'oversized untrusted label rejected',
  );
  stdout.writeln('PASS: 7 publishing error-copy checks');
}
